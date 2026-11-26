#!/bin/bash -

usage() {
	if [[ -n "$2" ]]
	then
		echo "$2"
	fi

	echo    "Usage: $1 [options...] NAMESPACE PVC FILE..."
	echo    ""
	echo    "Options"
	echo    "----"
	echo -e "  --image IMAGE  The image to use for the importer pod (must have sleep available; default is docker.io/alpine:latest)"
	echo -e "  --uid UID      The user ID to run the importer pod as (default is 65535)"
	echo -e "  --gid GID      The group ID to run the importer pod as (default is 65535)"
	echo -e "  --wipe         Fully wipes the PersistentVolumeClaim before copying files over"
	echo    ""
	echo    "Arguments"
	echo    "----"
	echo -e "NAMESPACE        The namespace to create the importer pod in"
	echo -e "PVC              The name of the PersistentVolumeClaim to import data to"
	echo -e "FILE...          The list of files or directories to import data from"
}

if [[ $# -lt 3 ]]
then
	usage $0 "Error: Unexpected number of arguments"
	exit 1
fi

IMAGE="docker.io/alpine:latest"
RUN_AS_UID=65535
RUN_AS_GID=65535
WIPE="false"

while true
do
	case "$1" in
		"--image")
			shift
			IMAGE="$1"
			shift
			;;
		"--uid")
			shift
			RUN_AS_UID="$1"
			if ! [[ "${RUN_AS_UID}" =~ ^[0-9]+$ ]]
			then
				usage $0 "Error: UID must be a positive integer"
				exit 1
			fi
			if [[ "${RUN_AS_UID}" -gt 65535 ]]
			then
				usage $0 "Error: UID cannot be larger than 65535"
				exit 1
			fi
			shift
			;;
		"--gid")
			shift
			RUN_AS_GID="$1"
			if ! [[ "${RUN_AS_GID}" =~ ^[0-9]+$ ]]
			then
				usage $0 "Error: GID must be a positive integer"
				exit 1
			fi
			if [[ "${RUN_AS_GID}" -gt 65535 ]]
			then
				usage $0 "Error: GID cannot be larger than 65535"
				exit 1
			fi
			shift
			;;
		"--wipe")
			shift
			WIPE="true"
			;;
		*)
			break
			;;
	esac
done

NAMESPACE="$1"
if ! kubectl get ns "${NAMESPACE}" >/dev/null 2>&1
then
	usage $0 "Error: Namespace not found"
	exit 1
fi
shift

PVC="$1"
if ! kubectl get pvc "${PVC}" -n "${NAMESPACE}" >/dev/null 2>&1
then
	usage $0 "Error: PersistentVolumeClaim not found"
	exit 1
fi
shift

for file in $@
do
	if ! [[ -e "${file}" ]]
	then
		usage $0 "Error: File not found '${file}'"
		exit 1
	fi
done

# Scary warning if wipe is set
if [[ "${WIPE}" = "true" ]]
then
	echo "WARNING: YOU HAVE SPECIFIED A FULL WIPE OF THE PERSISTENTVOLUMECLAIM, ANY EXISTING DATA WILL BE LOST FOREVER."
	echo -n "DO YOU UNDERSTAND THE RISKS? [Yes/n]: "
	read
	if [[ "$REPLY" != "Yes" ]]
	then
		exit 0
	fi
	echo -n "ARE YOU STILL POSITIVE YOU WANT TO DO THIS? [Yes wipe all data/n]: "
	read
	if [[ "$REPLY" != "Yes wipe all data" ]]
	then
		exit 0
	fi
else
	echo "WARNING: This will overwrite any existing files in the PersistentVolumeClaim that also exist in the speficied files"
	echo -n "Do you wish to proceed? [Yes/n]: "
	read
	if [[ "$REPLY" != "Yes" ]]
	then
		exit 0
	fi
fi

POD_OVERRIDES="$(cat << EOF
{
	"spec": {
		"terminationGracePeriodSeconds": 1,
		"securityContext": {
			"runAsUser": ${RUN_AS_UID},
			"fsGroup": ${RUN_AS_GID},
			"fsGroupChangePolicy": "OnRootMismatch"
		},
		"volumes": [
			{
				"name": "pvc",
				"persistentVolumeClaim": {
					"claimName": "${PVC}"
				}
			}
		],
		"containers": [
			{
				"name": "importer",
				"image": "${IMAGE}",
				"command": [
					"sleep",
					"infinity"
				],
				"volumeMounts": [
					{
						"name": "pvc",
						"mountPath": "/pvc"
					}
				]
			}
		]
	}
}
EOF
)"

echo "Starting importer pod"
kubectl run importer --image="${IMAGE}" -n "${NAMESPACE}" --overrides="${POD_OVERRIDES}" --override-type=merge
ERR=$?
if [[ "${ERR}" -ne 0 ]]
then
	exit "${ERR}"
fi

cleanup_pod() {
	kubectl delete pod importer -n "${NAMESPACE}"
}

trap cleanup_pod EXIT

echo "Waiting for importer pod to become Ready"
kubectl wait --for=condition=Ready pod/importer -n "${NAMESPACE}"
if [[ "${ERR}" -ne 0 ]]
then
	exit "${ERR}"
fi

if [[ "${WIPE}" = "true" ]]
then
	echo "Deleting existing files from PersistentVolumeClaim"
	kubectl exec -n "${NAMESPACE}" importer -- sh -c "rm -rf /pvc/*"
fi

for file in $@
do
	echo "Copying ${file}"
	kubectl cp -c importer -n "${NAMESPACE}" "${file}" "importer:/pvc/$(basename "${file}")"
	ERR=$?
	if [[ "${ERR}" -ne 0 ]]
	then
		exit "${ERR}"
	fi
done

echo "Done"
kubectl exec -n "${NAMESPACE}" importer -- ls -la /pvc

