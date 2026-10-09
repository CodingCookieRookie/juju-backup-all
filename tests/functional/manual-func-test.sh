#!/usr/bin/env bash
# Shell equivalent of tests/functional/test_backup.py, for running the functional tests by hand.
#
# Unlike the pytest suite, this does not deploy the k8s charm or register the k8s cloud on the
# client: it expects an existing k8s cloud (K8S_CLOUD) and bootstraps an LXD controller
# (CONTROLLER) if one does not exist yet. Re-running is safe: existing models, apps, secrets and
# relations are reused.
#
# Usage: tests/functional/manual-func-test.sh   (sets up the models, then runs the backup tests)
#
# Environment overrides:
#   CONTROLLER       LXD controller to bootstrap/use        (default: testingcontroller)
#   LXD_CLOUD        LXD cloud to bootstrap on              (default: localhost)
#   K8S_CLOUD        existing k8s cloud on the client       (default: juju-backup-all-k8s-cloud)
#   LXD_MODEL        model for machine charms               (default: jba-lxd)
#   K8S_MODEL        model for k8s charms                   (default: jba-k8s)
#   K8S_HOST_MODEL   if set, run kubectl as `sudo k8s kubectl` on k8s/0 in this model (it may be
#                    "controller:model"); otherwise the local `kubectl` is used
#   KUBE_CONTEXT     kubectl context for K8S_CLOUD (default: the context whose API server is
#                    K8S_CLOUD's endpoint, else a kubeconfig built from the Juju client's
#                    credential for K8S_CLOUD; the current context is never assumed)
#   K8S_NODE_IP      k8s node address MinIO TLS is reached on (default: first node's InternalIP)
#   WORKDIR          where the MinIO TLS cert/key are kept  (default: ~/.cache/jba-func-test)
#   NUM_UNITS        units per database cluster, except mysql-innodb which needs 3 (default: 2;
#                    the pytest suite uses 3). Only applies to apps not yet deployed.
#
# Requires: juju, jq, openssl, juju-backup-all, and kubectl access to the k8s cloud.

set -euo pipefail

CONTROLLER="${CONTROLLER:-testingcontroller}"
LXD_CLOUD="${LXD_CLOUD:-localhost}"
K8S_CLOUD="${K8S_CLOUD:-juju-backup-all-k8s-cloud}"
LXD_MODEL="${LXD_MODEL:-jba-lxd}"
K8S_MODEL="${K8S_MODEL:-jba-k8s}"
WORKDIR="${WORKDIR:-$HOME/.cache/jba-func-test}"
NUM_UNITS="${NUM_UNITS:-2}"

LXD="$CONTROLLER:$LXD_MODEL"
K8S="$CONTROLLER:$K8S_MODEL"

WAIT_TIMEOUT=$((30 * 60))
LONG_WAIT_TIMEOUT=$((100 * 60))
MINIO_ACCESS_KEY='ahs9ao#Fua'
MINIO_SECRET_KEY='ohCa!uB6oo'

# Mirrors jujubackupall.constants.SUPPORTED_BACKUP_CHARMS.
SUPPORTED_BACKUP_CHARMS=(
    mysql-innodb-cluster mysql mysql-k8s mongodb mongodb-k8s etcd
    postgresql postgresql-k8s zookeeper zookeeper-k8s
)

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

KUBECTL_ARGS=()

kctl() {
    if [[ -n "${K8S_HOST_MODEL:-}" ]]; then
        juju ssh -m "$K8S_HOST_MODEL" k8s/0 -- "sudo k8s kubectl $(printf '%q ' "$@")" | tr -d '\r'
    else
        kubectl "${KUBECTL_ARGS[@]}" "$@"
    fi
}

# Write a kubeconfig for K8S_CLOUD built from the Juju client's own cloud definition and
# credential (the service account `juju add-k8s` created), so no kubectl context is needed.
write_kubeconfig_from_juju() { # file
    local cloud_json cred_json
    cloud_json=$(juju show-cloud --client "$K8S_CLOUD" --format json)
    cred_json=$(juju credentials --client --show-secrets --format json |
        jq -c --arg c "$K8S_CLOUD" '.["client-credentials"][$c] // empty
            | .["cloud-credentials"][.["default-credential"] // (.["cloud-credentials"] | keys[0])]
            // empty')
    [[ -n $cred_json ]] || die "no client credential for $K8S_CLOUD (see: juju credentials --client)"
    (
        umask 077
        jq -n --argjson cloud "$cloud_json" --argjson cred "$cred_json" '
            ([$cloud | .. | objects | select(has("endpoint"))][0]) as $c
            | $cred.details as $d
            | {
                apiVersion: "v1", kind: "Config", "current-context": "juju",
                clusters: [{name: "juju", cluster: ({server: $c.endpoint}
                    + if ($c["ca-credentials"] // []) | length > 0
                      then {"certificate-authority-data": ($c["ca-credentials"] | join("\n") | @base64)}
                      else {"insecure-skip-tls-verify": true} end)}],
                users: [{name: "juju", user: (
                    {}
                    + if $d.Token then {token: $d.Token} else {} end
                    + if $d.ClientCertificateData then {
                        "client-certificate-data": ($d.ClientCertificateData | @base64),
                        "client-key-data": ($d.ClientKeyData | @base64)} else {} end
                    + if $d.username then {username: $d.username, password: $d.password} else {} end
                )}],
                contexts: [{name: "juju", context: {cluster: "juju", user: "juju"}}]
            }' >"$1"
    )
}

# Point kctl at the cluster behind K8S_CLOUD, not whatever kubectl's current context is (e.g.
# minikube), and check it is reachable before anything is deployed. In order of preference:
# K8S_HOST_MODEL, KUBE_CONTEXT, a kubectl context whose API server is the cloud's endpoint, and
# finally a kubeconfig built from the Juju client's credential for the cloud.
resolve_k8s_access() {
    local endpoint
    endpoint=$(juju show-cloud --client "$K8S_CLOUD" --format json 2>/dev/null |
        jq -r '[.. | objects | .endpoint? // empty][0] // empty') ||
        die "$K8S_CLOUD is not a cloud on this client (see: juju clouds --client)"
    [[ -n $endpoint ]] || die "could not read the API endpoint of $K8S_CLOUD"
    log "$K8S_CLOUD API server: $endpoint"

    if [[ -z ${K8S_HOST_MODEL:-} ]]; then
        command -v kubectl >/dev/null || die "kubectl is required (or set K8S_HOST_MODEL)"
        local context=${KUBE_CONTEXT:-}
        if [[ -z $context ]]; then
            context=$(kubectl config view -o json 2>/dev/null | jq -r --arg e "${endpoint%/}" '
                [(.clusters // [])[] | select((.cluster.server | rtrimstr("/")) == $e) | .name]
                    as $clusters
                | [(.contexts // [])[] | select(.context.cluster as $c | $clusters | index($c))
                    | .name][0] // empty') || true
        fi
        if [[ -n $context ]]; then
            log "Using kubectl context $context"
            KUBECTL_ARGS=(--context "$context")
        else
            mkdir -p "$WORKDIR"
            write_kubeconfig_from_juju "$WORKDIR/kubeconfig"
            log "Using kubeconfig built from the Juju credential for $K8S_CLOUD"
            KUBECTL_ARGS=(--kubeconfig "$WORKDIR/kubeconfig")
        fi
    fi
    kctl get --raw /version >/dev/null || die "cannot reach the $K8S_CLOUD API server ($endpoint)"
}

kubeconfig() {
    if [[ -n "${K8S_HOST_MODEL:-}" ]]; then
        juju ssh -m "$K8S_HOST_MODEL" k8s/0 -- sudo k8s config | tr -d '\r'
    else
        kctl config view --raw --minify --flatten
    fi
}

# --- Juju helpers ---

app_exists() { # model app
    juju status -m "$1" --format json | jq -e --arg a "$2" '.applications | has($a)' >/dev/null
}

# Retries, since a loaded k8s API server can fail a deploy transiently (e.g. "etcdserver: request
# timed out"). The app is re-checked on each attempt in case a failed deploy still created it.
deploy() { # model app charm [juju deploy args...]
    local model=$1 app=$2 charm=$3 attempt out
    shift 3
    for attempt in 1 2 3 4 5; do
        if app_exists "$model" "$app"; then
            ((attempt > 1)) || log "$app already deployed in $model, skipping"
            return
        fi
        log "Deploying $app ($charm) to $model"
        if out=$(juju deploy -m "$model" "$charm" "$app" "$@" 2>&1); then
            printf '%s\n' "$out" >&2
            return
        fi
        printf '%s\n' "$out" >&2
        [[ $out != *"selecting releases"* ]] || die "no release of $charm matches the requested channel/base"
        log "Deploying $app failed (attempt $attempt/5); retrying in 30s"
        sleep 30
    done
    die "could not deploy $app to $model"
}

integrate() { # model app1 app2
    local out
    if ! out=$(juju integrate -m "$1" "$2" "$3" 2>&1); then
        [[ $out == *"already exists"* ]] || die "integrate $2 $3 failed: $out"
    fi
}

get_or_add_secret() { # model name key=value...
    local model=$1 name=$2 uri
    shift 2
    if uri=$(juju add-secret -m "$model" "$name" "$@" 2>/dev/null); then
        echo "$uri"
        return
    fi
    uri=$(juju secrets -m "$model" --format json |
        jq -r --arg n "$name" 'to_entries[] | select(.value.label == $n or .value.name == $n) | .key' |
        head -n1)
    [[ -n $uri ]] || die "could not create or find secret $name in $model"
    [[ $uri == secret:* ]] || uri="secret:$uri"
    echo "$uri"
}

# wait_for MODEL TIMEOUT IDLE FAIL_FAST EXTRA_JQ [APP...]
#   Wait until every APP (all apps if none given) is active, like jubilant.all_active; with
#   IDLE=1 also require idle agents, like jubilant.all_agents_idle.
#   FAIL_FAST: JSON array of apps whose error status aborts the wait ("[]" = all, "null" = none).
#   EXTRA_JQ: additional jq predicate on the status that must also hold ("true" for none).
wait_for() {
    local model=$1 timeout=$2 idle=$3 fail_fast=$4 extra=$5
    shift 5
    local apps status errored deadline=$((SECONDS + timeout))
    apps=$(jq -nc '$ARGS.positional' --args "$@")
    log "Waiting for ${*:-all apps} in $model (idle=$idle, timeout=${timeout}s)"
    while :; do
        if status=$(juju status -m "$model" --format json 2>/dev/null); then
            if [[ $fail_fast != null ]]; then
                errored=$(jq -r --argjson ff "$fail_fast" '
                    . as $s
                    | (if ($ff | length) == 0 then ($s.applications | keys) else $ff end)
                    | [.[] as $n | $s.applications[$n] // empty
                        | select(.["application-status"].current == "error"
                            or any((.units // {})[];
                                .["workload-status"].current == "error"
                                or .["juju-status"].current == "error"))
                        | $n]
                    | join(",")' <<<"$status")
                [[ -z $errored ]] || die "apps in error in $model: $errored"
            fi
            if jq -e --argjson apps "$apps" --argjson idle "$idle" "
                . as \$s
                | (if (\$apps | length) == 0 then (\$s.applications | keys) else \$apps end)
                | all(.[]; . as \$n | \$s.applications[\$n] as \$app
                    | \$app != null
                    and \$app[\"application-status\"].current == \"active\"
                    and ((\$app.units // {}) | length) > 0
                    and all((\$app.units // {})[];
                        .[\"workload-status\"].current == \"active\"
                        and (\$idle == 0 or .[\"juju-status\"].current == \"idle\")))
                and (\$s | $extra)" <<<"$status" >/dev/null; then
                return
            fi
        fi
        ((SECONDS < deadline)) || die "timed out waiting for ${*:-all apps} in $model"
        sleep 15
    done
}

# A mysql-innodb member can stay blocked with "Cluster is inaccessible from this instance" once
# the cluster has formed, so trust the cluster-wide view instead (see innodb_cluster_online).
INNODB_CLUSTER_ONLINE='any(.applications["mysql-innodb"].units[];
    .["workload-status"].current == "active"
    and ((.["workload-status"].message // "") | contains("can tolerate up to ONE failure")))'

expose_via_loadbalancer() { # app -> prints external IP
    local app=$1 ip deadline=$((SECONDS + 300))
    kctl -n "$K8S_MODEL" patch svc "$app" -p '{"spec": {"type": "LoadBalancer"}}' >&2
    while :; do
        ip=$(kctl -n "$K8S_MODEL" get svc "$app" -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
        [[ -z $ip ]] || break
        ((SECONDS < deadline)) || die "no LoadBalancer IP assigned to $app"
        sleep 5
    done
    echo "$ip"
}

expose_via_nodeport() { # app port -> prints node port
    kctl -n "$K8S_MODEL" patch svc "$1" -p '{"spec": {"type": "NodePort"}}' >&2
    kctl -n "$K8S_MODEL" get svc "$1" -o jsonpath="{.spec.ports[?(@.port==$2)].nodePort}"
}

generate_self_signed_cert() { # ip -> writes $WORKDIR/minio-tls.{key,crt}
    mkdir -p "$WORKDIR"
    if [[ -s $WORKDIR/minio-tls.crt && -s $WORKDIR/minio-tls.key ]] &&
        openssl x509 -in "$WORKDIR/minio-tls.crt" -noout -ext subjectAltName 2>/dev/null |
        grep -qx " *IP Address:$1"; then
        log "Reusing MinIO TLS cert in $WORKDIR"
        return
    fi
    cat >"$WORKDIR/minio-tls.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = minio.example.test
[v3]
basicConstraints = critical,CA:TRUE
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always
subjectAltName = IP:$1
EOF
    openssl genrsa -traditional -out "$WORKDIR/minio-tls.key" 2048 2>/dev/null
    openssl req -x509 -new -key "$WORKDIR/minio-tls.key" -days 365 \
        -config "$WORKDIR/minio-tls.cnf" -out "$WORKDIR/minio-tls.crt"
}

# --- Setup (test_build_and_deploy) ---

setup() {
    if ! juju controllers --format json | jq -e --arg c "$CONTROLLER" '.controllers | has($c)' >/dev/null; then
        log "Bootstrapping $CONTROLLER on $LXD_CLOUD"
        juju bootstrap "$LXD_CLOUD" "$CONTROLLER"
    fi
    if ! juju clouds -c "$CONTROLLER" --format json | jq -e --arg c "$K8S_CLOUD" 'has($c)' >/dev/null; then
        log "Adding $K8S_CLOUD to $CONTROLLER"
        kubeconfig | juju add-k8s "$K8S_CLOUD" --controller "$CONTROLLER"
    fi
    for model_cloud in "$LXD_MODEL:$LXD_CLOUD" "$K8S_MODEL:$K8S_CLOUD"; do
        local model=${model_cloud%%:*} cloud=${model_cloud#*:}
        if ! juju models -c "$CONTROLLER" --format json |
            jq -e --arg m "$model" '.models | any(."short-name" == $m)' >/dev/null; then
            juju add-model -c "$CONTROLLER" "$model" "$cloud" --no-switch
        fi
    done

    local s3_secret_lxd s3_secret_k8s
    s3_secret_lxd=$(get_or_add_secret "$LXD" s3-credentials \
        "access-key=$MINIO_ACCESS_KEY" "secret-key=$MINIO_SECRET_KEY")

    # --- Minio S3 storage ---

    deploy "$K8S" minio minio --channel ckf-1.10/stable --trust \
        --config "access-key=$MINIO_ACCESS_KEY" --config "secret-key=$MINIO_SECRET_KEY"

    # PostgreSQL (pgBackRest) only supports S3 over HTTPS, but some other apps like mysql do not
    # support self-signed TLS certificates, so PostgreSQL gets its own MinIO with TLS, exposed via
    # NodePort on the k8s node since the LoadBalancer IP is taken by "minio".
    local k8s_node_ip=${K8S_NODE_IP:-}
    if [[ -z $k8s_node_ip ]]; then
        # A dual-stack node lists both an IPv4 and an IPv6 InternalIP; use the IPv4 one, as the
        # pytest suite does with the k8s unit's address.
        k8s_node_ip=$(kctl get nodes -o json | jq -r '
            [.items[0].status.addresses[] | select(.type == "InternalIP") | .address
                | select(test("^[0-9]+(\\.[0-9]+){3}$"))][0] // empty')
    fi
    [[ $k8s_node_ip =~ ^[0-9]+(\.[0-9]+){3}$ ]] ||
        die "could not determine the k8s node's IPv4 address (got '$k8s_node_ip'); set K8S_NODE_IP"
    log "k8s node IP: $k8s_node_ip"
    generate_self_signed_cert "$k8s_node_ip"
    local cert_base64
    cert_base64=$(base64 -w0 "$WORKDIR/minio-tls.crt")
    deploy "$K8S" minio-tls minio --channel ckf-1.10/stable --trust \
        --config "access-key=$MINIO_ACCESS_KEY" --config "secret-key=$MINIO_SECRET_KEY" \
        --config "ssl-cert=$cert_base64" \
        --config "ssl-key=$(base64 -w0 "$WORKDIR/minio-tls.key")"

    # --- Database Applications ---

    # mysql-innodb stays at 3 units: INNODB_CLUSTER_ONLINE waits for "can tolerate up to ONE
    # failure", which a smaller cluster never reports.
    deploy "$LXD" mysql-innodb mysql-innodb-cluster --base ubuntu@22.04 --channel 8.0/stable -n 3
    deploy "$LXD" postgresql postgresql --base ubuntu@24.04 --channel 16/stable -n "$NUM_UNITS"
    deploy "$K8S" postgresql-k8s postgresql-k8s --base ubuntu@24.04 --channel 16/stable --trust \
        -n "$NUM_UNITS"
    deploy "$LXD" mysql mysql --base ubuntu@22.04 --channel 8.0/stable -n "$NUM_UNITS"
    deploy "$K8S" mysql-k8s mysql-k8s --base ubuntu@22.04 --channel 8.0/stable --trust -n "$NUM_UNITS"
    deploy "$LXD" mongodb mongodb --base ubuntu@24.04 --channel 8/stable -n "$NUM_UNITS"
    deploy "$K8S" mongodb-k8s mongodb-k8s --base ubuntu@22.04 --channel 6/stable --trust \
        -n "$NUM_UNITS"
    deploy "$LXD" zookeeper zookeeper --base ubuntu@22.04 --channel 3/stable -n "$NUM_UNITS"
    deploy "$K8S" zookeeper-k8s zookeeper-k8s --base ubuntu@22.04 --channel 3/stable -n "$NUM_UNITS"
    deploy "$LXD" etcd etcd --base ubuntu@22.04 --channel stable -n 1
    deploy "$LXD" easyrsa easyrsa --base ubuntu@22.04 --channel stable -n 1
    integrate "$LXD" etcd:certificates easyrsa:client

    # --- Deploy s3-integrators and configure s3-credentials for charms ---

    # MinIO's config hook resets its Service to ClusterIP, so let minio-tls settle before
    # exposing it.
    wait_for "$K8S" "$WAIT_TIMEOUT" 0 null true minio
    wait_for "$K8S" "$WAIT_TIMEOUT" 1 null true minio-tls

    # Let the database clusters finish forming before relating them to S3; their hooks can fail
    # transiently while the clusters form and Juju retries them, so don't fail fast here.
    wait_for "$LXD" "$LONG_WAIT_TIMEOUT" 1 null true mysql mongodb zookeeper
    wait_for "$K8S" "$LONG_WAIT_TIMEOUT" 1 null true mysql-k8s mongodb-k8s zookeeper-k8s

    local minio_ip
    minio_ip=$(expose_via_loadbalancer minio)
    s3_secret_k8s=$(get_or_add_secret "$K8S" s3-credentials \
        "access-key=$MINIO_ACCESS_KEY" "secret-key=$MINIO_SECRET_KEY")
    local model secret app
    for entry in \
        "$LXD|$s3_secret_lxd|mysql" \
        "$LXD|$s3_secret_lxd|mongodb" \
        "$LXD|$s3_secret_lxd|zookeeper" \
        "$K8S|$s3_secret_k8s|mysql-k8s" \
        "$K8S|$s3_secret_k8s|mongodb-k8s" \
        "$K8S|$s3_secret_k8s|zookeeper-k8s"; do
        IFS='|' read -r model secret app <<<"$entry"
        deploy "$model" "s3-integrator-$app" s3-integrator --channel 2/stable \
            --config "endpoint=http://$minio_ip:9000" \
            --config "bucket=$app-backups" \
            --config "region=us-east-1" \
            --config "s3-uri-style=path"
        juju grant-secret -m "$model" s3-credentials "s3-integrator-$app"
        juju config -m "$model" "s3-integrator-$app" "credentials=$secret"
        integrate "$model" "$app" "s3-integrator-$app"
    done

    local minio_tls_port
    minio_tls_port=$(expose_via_nodeport minio-tls 9000)
    for entry in \
        "$LXD|$s3_secret_lxd|postgresql" \
        "$K8S|$s3_secret_k8s|postgresql-k8s"; do
        IFS='|' read -r model secret app <<<"$entry"
        deploy "$model" "s3-integrator-$app" s3-integrator --channel 2/stable \
            --config "endpoint=https://$k8s_node_ip:$minio_tls_port" \
            --config "bucket=$app-backups" \
            --config "path=$app" \
            --config "region=" \
            --config "s3-uri-style=path" \
            --config "tls-ca-chain=$cert_base64"
        juju grant-secret -m "$model" s3-credentials "s3-integrator-$app"
        juju config -m "$model" "s3-integrator-$app" "credentials=$secret"
        wait_for "$model" "$WAIT_TIMEOUT" 0 "[\"s3-integrator-$app\"]" true "s3-integrator-$app"
        integrate "$model" "$app" "s3-integrator-$app"
    done

    # --- Wait all to be ready ---

    wait_for "$LXD" "$LONG_WAIT_TIMEOUT" 0 '[]' "$INNODB_CLUSTER_ONLINE" \
        postgresql s3-integrator-postgresql mysql mongodb zookeeper etcd easyrsa \
        s3-integrator-mysql s3-integrator-mongodb s3-integrator-zookeeper
    # mongodb-k8s's s3-credentials-relation-changed hook can fail transiently even on a settled
    # cluster, and Juju retries it, so don't fail fast on it.
    local k8s_fail_fast_apps
    k8s_fail_fast_apps=$(juju status -m "$K8S" --format json |
        jq -c '.applications | keys - ["mongodb-k8s"]')
    wait_for "$K8S" "$LONG_WAIT_TIMEOUT" 1 "$k8s_fail_fast_apps" true
    log "Setup complete"
}

# --- Tests ---

# run_backup KEEP_CHARM OUTDIR [juju-backup-all args...] -> prints JSON output.
# Excludes every supported charm except KEEP_CHARM ("" excludes all).
run_backup() {
    local keep=$1 outdir=$2 excludes=() charm
    shift 2
    for charm in "${SUPPORTED_BACKUP_CHARMS[@]}"; do
        [[ $charm == "$keep" ]] || excludes+=(-e "$charm")
    done
    juju-backup-all -c "$CONTROLLER" -o "$outdir" "${excludes[@]}" "$@"
}

check() { # description command...
    local desc=$1
    shift
    "$@" || { log "  assertion failed: $desc"; exit 1; }
}

jq_check() { # description json filter [jq args...]
    local desc=$1 json=$2 filter=$3
    shift 3
    check "$desc" jq -e "$@" "$filter" <<<"$json" >/dev/null
}

# check_app_backup MODEL APP CHARM STRICT ARTIFACT [juju-backup-all args...]
#   STRICT=1 requires exactly one app backup entry (the operator tests); 0 checks the first.
#   ARTIFACT: "gz:<glob>" for a downloaded dump, "txt" for an S3 backup id, or "json" for
#   PostgreSQL create-backup metadata.
check_app_backup() {
    local model=$1 app=$2 charm=$3 strict=$4 artifact=$5
    shift 5
    local outdir output app_charm expected_dir model_name=${model#*:}
    outdir=$(mktemp -d)
    output=$(run_backup "$charm" "$outdir" -x -j "$@") || { log "  juju-backup-all failed"; exit 1; }
    app_charm=$(juju status -m "$model" --format json | jq -r --arg a "$app" '.applications[$a].charm')
    expected_dir="$outdir/$CONTROLLER/$model_name/$app"

    if ((strict)); then
        jq_check "exactly one app backup" "$output" '.app_backups | length == 1'
    fi
    jq_check "download path under $outdir" "$output" \
        '.app_backups | any(.download_path | contains($o))' --arg o "$outdir"
    jq_check "controller is $CONTROLLER" "$output" '.app_backups[0].controller == $c' --arg c "$CONTROLLER"
    jq_check "model is $model_name" "$output" '.app_backups | any(.model == $m)' --arg m "$model_name"
    jq_check "charm matches $app_charm" "$output" \
        '.app_backups[0].charm as $c | $ac | contains($c)' --arg ac "$app_charm"
    check "$expected_dir exists" test -d "$expected_dir"

    local files
    case $artifact in
    gz:*)
        check "${artifact#gz:} downloaded" compgen -G "$expected_dir/${artifact#gz:}" >/dev/null
        ;;
    txt)
        files=("$expected_dir/$app"-backup-metadata-*.txt)
        check "one metadata file" test "${#files[@]}" -eq 1 -a -s "${files[0]}"
        ;;
    json)
        files=("$expected_dir/$app"-backup-metadata-*.json)
        check "one metadata file" test "${#files[@]}" -eq 1 -a -f "${files[0]}"
        check "backup-status is 'backup created'" \
            jq -e '."backup-status" == "backup created"' "${files[0]}" >/dev/null
        ;;
    esac
    rm -rf "$outdir"
}

test_juju_controller_backup() {
    local outdir output
    outdir=$(mktemp -d)
    output=$(run_backup "" "$outdir" -j) || { log "  juju-backup-all failed"; exit 1; }
    jq_check "download path under $outdir" "$output" \
        '.controller_backups[0].download_path | contains($o)' --arg o "$outdir"
    jq_check "controller is $CONTROLLER" "$output" \
        '.controller_backups[0].controller == $c' --arg c "$CONTROLLER"
    check "controller backup downloaded" \
        compgen -G "$outdir/$CONTROLLER/juju-controller-backup*.gz" >/dev/null
    rm -rf "$outdir"
}

test_juju_client_config_backup() {
    local outdir output
    outdir=$(mktemp -d)
    output=$(run_backup "" "$outdir" -x) || { log "  juju-backup-all failed"; exit 1; }
    jq_check "download path under $outdir" "$output" \
        '.config_backups[0].download_path | contains($o)' --arg o "$outdir"
    jq_check "config is juju" "$output" '.config_backups[0].config == "juju"'
    check "client config downloaded" compgen -G "$outdir/local_configs/juju-*.gz" >/dev/null
    rm -rf "$outdir"
}

PASSED=()
FAILED=()

run_test() { # name command...
    local name=$1
    shift
    log "RUN  $name"
    if ("$@"); then
        log "PASS $name"
        PASSED+=("$name")
    else
        log "FAIL $name"
        FAILED+=("$name")
    fi
}

run_tests() {
    command -v juju-backup-all >/dev/null || die "juju-backup-all is not on PATH"
    local loc
    for loc in /var/backups/mysql /home/ubuntu/abc; do
        run_test "mysql_innodb_backup[$loc]" check_app_backup "$LXD" mysql-innodb \
            mysql-innodb-cluster 0 "gz:mysqldump-all-databases*.gz" --backup-location-on-mysql "$loc"
    done
    run_test mysql_operator_backup check_app_backup "$LXD" mysql mysql 1 txt
    run_test mongodb_operator_backup check_app_backup "$LXD" mongodb mongodb 1 txt
    run_test mysql_k8s_operator_backup check_app_backup "$K8S" mysql-k8s mysql-k8s 1 txt
    run_test mongodb_k8s_operator_backup check_app_backup "$K8S" mongodb-k8s mongodb-k8s 1 txt
    run_test zookeeper_operator_backup check_app_backup "$LXD" zookeeper zookeeper 1 txt
    run_test zookeeper_k8s_operator_backup check_app_backup "$K8S" zookeeper-k8s zookeeper-k8s 1 txt
    for loc in /home/ubuntu/etcd-snapshots /home/ubuntu/abc; do
        run_test "etcd_backup[$loc]" check_app_backup "$LXD" etcd etcd 0 \
            "gz:etcd-snapshot*.gz" --backup-location-on-etcd "$loc"
    done
    run_test juju_controller_backup test_juju_controller_backup
    run_test juju_client_config_backup test_juju_client_config_backup
    for loc in /home/ubuntu /home/ubuntu/abc; do
        run_test "postgresql_backup[$loc]" check_app_backup "$LXD" postgresql postgresql 1 json \
            --backup-location-on-postgresql "$loc"
    done
    run_test postgresql_k8s_operator_backup check_app_backup "$K8S" postgresql-k8s postgresql-k8s 1 json

    log "${#PASSED[@]} passed, ${#FAILED[@]} failed"
    ((${#FAILED[@]} == 0)) || { printf '  FAILED: %s\n' "${FAILED[@]}" >&2; return 1; }
}

for tool in juju jq openssl juju-backup-all; do
    command -v "$tool" >/dev/null || die "$tool is required"
done

resolve_k8s_access
setup
run_tests

