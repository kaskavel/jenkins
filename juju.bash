#!/bin/bash
#
# Juju helpers

vergte() {
    [  "$2" = "`echo -e "$1\n$2" | sort -V | head -n1`" ]
}

verlte() {
    [  "$1" = "`echo -e "$1\n$2" | sort -V | head -n1`" ]
}

verlt() {
    [ "$1" = "$2" ] && return 1 || verlte $1 $2
}

function juju::bootstrap::before
{
    echo "> skipping before tasks"
}

function juju::bootstrap::after
{
    echo "> skipping after tasks"
}

function juju::version
{
    # yields the short sem version of juju
    # "3.1.0-genericlinux-amd64" becomes "3.1"
    juju --version|cut -f-2 -d.
}

function juju::version_2
{
    verlt $(juju::version) 3.0.0
}

function juju::version_3
{
    vergte $(juju::version) 3.0.0
}

function juju::pip::2.9
{
    # Pin python libjuju to operate with juju 2.9
    if juju::version_2; then
        echo "juju 2.9 environment detected"
        echo "Pinning back python libjuju before starting tests"
        pip-sync "requirements-2.9.txt"
    fi
}

function juju::bootstrap
{
    extra_args='--model-default image-stream=daily'
    if [ "$JUJU_CLOUD" = "azure/centralus" ]; then
        # Azure seems to have trouble with the daily image-stream
        extra_args=''
    fi
    if [ "$JUJU_CLOUD" = "vsphere/Boston" ]; then
        extra_args="$extra_args \
            --model-default datastore=vsanDatastore \
            --model-default primary-network=VLAN_2763 \
            --model-default force-vm-hardware-version=17 \
            --config caas-image-repo=rocks.canonical.com/cdk/jujusolutions \
            --bootstrap-image=juju-ci-root/templates/$SERIES-test-template"
    fi
    if juju::version_2; then
        add_model=("-d ${JUJU_MODEL}")
    else
        add_model=("--add-model ${JUJU_MODEL}")
    fi

    juju bootstrap "$JUJU_CLOUD" "$JUJU_CONTROLLER" \
         ${add_model[@]} \
         --force --bootstrap-series "$SERIES" \
         --bootstrap-constraints arch="${ARCH:-amd64}" \
         --model-default test-mode=true \
         --model-default resource-tags=owner=k8sci \
         --model-default automatically-retry-hooks=true \
         --model-default logging-config="<root>=DEBUG" \
         $extra_args

    ret=$?
    if (( ret > 0 )); then
        exit "$ret"
    fi
}

function juju::deploy::before
{
    echo "> skipping before tasks"
}

function juju::deploy::after
{
    echo "> skipping after tasks"
}

function juju::deploy::overlay
{
    local constraints
    constraints="arch=${ARCH:-amd64} cores=2 mem=8G root-disk=16G"

    cat <<EOF > overlay.yaml
series: $SERIES
applications:
  kubernetes-control-plane:
    constraints: $constraints
    options:
      channel: $SNAP_VERSION
  kubernetes-worker:
    constraints: $constraints
    options:
      channel: $SNAP_VERSION
EOF
}

function juju::deploy
{
    juju deploy -m "$JUJU_CONTROLLER:$JUJU_MODEL" \
         --overlay overlay.yaml \
         --force \
         --channel "$JUJU_DEPLOY_CHANNEL" "$JUJU_DEPLOY_BUNDLE"

    juju::deploy-report $?
}

function juju::wait
{
    echo "Waiting for deployment to settle..."
    timeout 45m juju-wait -e "$JUJU_CONTROLLER:$JUJU_MODEL" -w

    juju::deploy-report $?
}

function juju::unitAddress
{
    py_script="
import sys
import yaml

status_yaml=yaml.safe_load(sys.stdin)
unit = status_yaml['applications']['$1']['units']
units = list(unit.keys())
print(unit[units[0]]['public-address'])
"
    juju status -m "$JUJU_CONTROLLER:$JUJU_MODEL" "$1" --format yaml | env python3 -c "$py_script"
}

function juju::deploy-report
{
    # report deployment failure
    local ret=$1

    local is_pass="True"
    if (( ret > 0 )); then
        is_pass="False"
    fi
    kv::set "deploy_result" "${is_pass}"
    kv::set "deploy_endtime" "$(timestamp)"
    touch "meta/deployresult-${is_pass}"
    python bin/s3 cp "meta/deployresult-${is_pass}" "meta/deployresult-${is_pass}"

    if (( ret > 0 )); then
        test::report ${is_pass}
        exit $ret
    fi
}