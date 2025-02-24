#!/usr/bin/env bash
# Copyright The Enterprise Contract Contributors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# SPDX-License-Identifier: Apache-2.0

# Updates the rpms.lock.yaml file

set -o errexit
set -o pipefail
set -o nounset

root_dir=$(git rev-parse --show-toplevel)

latest_release=$(gh api '/repos/konflux-ci/rpm-lockfile-prototype/tags?per_page=1' --jq '.[0].name')

# build the image for running the RPM lock tool
echo Building RPM lock tooling image...
image=$(podman build --quiet --file <(cat <<DOCKERFILE
FROM quay.io/openshift/origin-cli:latest as oc-cli

# Python version needs to match whatever version of Python dnf itself depends on
FROM registry.access.redhat.com/ubi9/python-39:latest

# need to switch to root for dnf install below and for the script to run dnf
# config-manager which demands root user
USER 0

RUN dnf install --assumeyes --nodocs --setopt=keepcache=0 --refresh skopeo jq

RUN pip install https://github.com/konflux-ci/rpm-lockfile-prototype/archive/refs/tags/${latest_release}.tar.gz
RUN pip install dockerfile-parse

COPY --from=oc-cli /usr/bin/oc /usr/bin

ENV PYTHONPATH=/usr/lib64/python3.9/site-packages:/usr/lib/python3.9/site-packages
DOCKERFILE
))

echo "Built: ${image}"

# script that performs everything within the image built above
script="$(cat <<"RPM_LOCK_SCRIPT"
set -o errexit
set -o pipefail
set -o nounset

# determine the base image
base_img=$(python <<SCRIPT
from dockerfile_parse import DockerfileParser

with open("Dockerfile", "r") as d:
    dfp = DockerfileParser(fileobj=d)
    # the last FROM image is the image we want to base on
    print(dfp.parent_images[-1])
SCRIPT
)

echo $base_img

# where the .repo files will be extracted from the base image
base_image_repos=$(mktemp -d --tmpdir)

# extract all /etc/yum.repos.d/* files from the base image
oc image extract "${base_img}" --path /etc/yum.repos.d/*.repo:"${base_image_repos}"

# enable source repositories
for r in $(dnf repolist --setopt=reposdir="${base_image_repos}" --disabled --quiet|grep -- -source | sed "s/ .*//"); do
    dnf config-manager --quiet --setopt=reposdir="${base_image_repos}" "${r}" --set-enabled
done

# convert ubi repo ids to archful format for better sbom data
sed -i 's/^\[ubi-9-/\[ubi-9-for-$basearch-/' "${base_image_repos}"/*.repo

cp "${base_image_repos}"/*.repo /opt/app-root/src/

# generate/update the RPM lock file
/opt/app-root/bin/rpm-lockfile-prototype --outfile rpms.lock.yaml --image "${base_img}" rpms.in.yaml

RPM_LOCK_SCRIPT
)"

if [ ! -f "${root_dir}/rpms.lock.yaml" ]; then
    touch "${root_dir}/rpms.lock.yaml"
fi

# If you see something like this:
#   PermissionError: [Errno 13] Permission denied: 'Dockerfile'
# then try adding the --privileged flag to the podman run command
echo Running RPM lock tooling...
podman run \
    --privileged \
    --rm \
    --mount type=bind,source="${root_dir}/Dockerfile.dist",destination=/opt/app-root/src/Dockerfile \
    --mount type=bind,source="${root_dir}/rpms.in.yaml",destination=/opt/app-root/src/rpms.in.yaml \
    --mount type=bind,source="${root_dir}/rpms.lock.yaml",destination=/opt/app-root/src/rpms.lock.yaml \
    "${image}" \
    bash -c "${script}"

# shellcheck disable=SC2094
cat <<< "$(cat <<EOF
# Copyright The Enterprise Contract Contributors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# SPDX-License-Identifier: Apache-2.0
#
# This file is generated by hack/update-rpm-lock.sh
$(<"${root_dir}/rpms.lock.yaml")
EOF
)" > "${root_dir}/rpms.lock.yaml"
