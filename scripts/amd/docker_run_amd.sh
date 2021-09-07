set -o xtrace

alias drun='sudo docker run -it --rm --network=host --group-add video --cap-add=SYS_PTRACE --security-opt seccomp=unconfined'

DEVICES="--device=/dev/kfd --device=/dev/dri"

MEMORY="--ipc=host --shm-size 16G"

VOLUMES="-v $HOME/dockerx:/dockerx -v /data:/data"

# WORK_DIR='/root/apex'
WORK_DIR='/dockerx/apex_rocm'

IMAGE_NAME=rocm/pytorch
#  IMAGE_NAME=rocm/pytorch:rocm4.3_ubuntu18.04_py3.6_pytorch


CONTAINER_ID=$(drun -d -w $WORK_DIR $MEMORY $VOLUMES $DEVICES $IMAGE_NAME)
echo "CONTAINER_ID: $CONTAINER_ID"
# docker cp . $CONTAINER_ID:$WORK_DIR
docker attach $CONTAINER_ID
docker stop $CONTAINER_ID
docker rm $CONTAINER_ID
