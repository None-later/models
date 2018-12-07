#!/usr/bin/env bash
#
# -*- coding: utf-8 -*-
#
# Copyright (c) 2018 Intel Corporation
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# SPDX-License-Identifier: EPL-2.0
#

echo 'Running with parameters:'
echo "    USE_CASE: ${USE_CASE}"
echo "    FRAMEWORK: ${FRAMEWORK}"
echo "    WORKSPACE: ${WORKSPACE}"
echo "    DATASET_LOCATION: ${DATASET_LOCATION}"
echo "    CHECKPOINT_DIRECTORY: ${CHECKPOINT_DIRECTORY}"
echo "    IN_GRAPH: ${IN_GRAPH}"
echo '    Mounted volumes:'
echo "        ${BENCHMARK_SCRIPTS} mounted on: ${MOUNT_BENCHMARK}"
echo "        ${EXTERNAL_MODELS_SOURCE_DIRECTORY} mounted on: ${MOUNT_EXTERNAL_MODELS_SOURCE}"
echo "        ${INTELAI_MODELS} mounted on: ${MOUNT_INTELAI_MODELS_SOURCE}"
echo "        ${DATASET_LOCATION_VOL} mounted on: ${DATASET_LOCATION}"
echo "        ${CHECKPOINT_DIRECTORY_VOL} mounted on: ${CHECKPOINT_DIRECTORY}"
echo "    SINGLE_SOCKET: ${SINGLE_SOCKET}"
echo "    MODEL_NAME: ${MODEL_NAME}"
echo "    MODE: ${MODE}"
echo "    PLATFORM: ${PLATFORM}"
echo "    BATCH_SIZE: ${BATCH_SIZE}"
echo "    NUM_CORES: ${NUM_CORES}"
echo "    BENCHMARK_ONLY: ${BENCHMARK_ONLY}"
echo "    ACCURACY_ONLY: ${ACCURACY_ONLY}"

# Only inference is supported right now
if [ ${MODE} != "inference" ]; then
  echo "${MODE} mode is not supported"
  exit 1
fi

## install common dependencies
apt update
apt full-upgrade -y
apt-get install python-tk numactl -y
apt install -y libsm6 libxext6
pip install --upgrade pip
pip install requests

single_socket_arg=""
if [ ${SINGLE_SOCKET} == "True" ]; then
  single_socket_arg="--single-socket"
fi

verbose_arg=""
if [ ${VERBOSE} == "True" ]; then
  verbose_arg="--verbose"
fi

accuracy_only_arg=""
if [ ${ACCURACY_ONLY} == "True" ]; then
  accuracy_only_arg="--accuracy-only"
fi

benchmark_only_arg=""
if [ ${BENCHMARK_ONLY} == "True" ]; then
  benchmark_only_arg="--benchmark-only"
fi

RUN_SCRIPT_PATH="common/${FRAMEWORK}/run_tf_benchmark.py"

LOG_OUTPUT=${WORKSPACE}/logs
timestamp=`date +%Y%m%d_%H%M%S`
LOG_FILENAME="benchmark_${MODEL_NAME}_${MODE}_${PLATFORM}_${timestamp}.log"
if [ ! -d "${LOG_OUTPUT}" ]; then
  mkdir ${LOG_OUTPUT}
fi

export PYTHONPATH=${PYTHONPATH}:${MOUNT_INTELAI_MODELS_SOURCE}

# Common execution command used by all models
function run_model() {
  # Navigate to the main benchmark directory before executing the script,
  # since the scripts use the benchmark/common scripts as well.
  cd ${MOUNT_BENCHMARK}

  # Start benchmarking
  eval ${CMD} 2>&1 | tee ${LOGFILE}

  if [ ${VERBOSE} == "True" ]; then
    echo "PYTHONPATH: ${PYTHONPATH}" | tee -a ${LOGFILE}
    echo "RUNCMD: ${CMD} " | tee -a ${LOGFILE}
    echo "Batch Size: ${BATCH_SIZE}" | tee -a ${LOGFILE}
  fi
  echo "Ran ${MODE} with batch size ${BATCH_SIZE}" | tee -a ${LOGFILE}

  LOG_LOCATION_OUTSIDE_CONTAINER="${BENCHMARK_SCRIPTS}/common/${FRAMEWORK}/logs/${LOG_FILENAME}"
  echo "Log location outside container: ${LOG_LOCATION_OUTSIDE_CONTAINER}" | tee -a ${LOGFILE}
}

# basic run command with commonly used args
CMD="python ${RUN_SCRIPT_PATH} \
--framework=${FRAMEWORK} \
--use-case=${USE_CASE} \
--model-name=${MODEL_NAME} \
--platform=${PLATFORM} \
--mode=${MODE} \
--model-source-dir=${MOUNT_EXTERNAL_MODELS_SOURCE} \
--intelai-models=${MOUNT_INTELAI_MODELS_SOURCE} \
--num-cores=${NUM_CORES} \
--batch-size=${BATCH_SIZE} \
${single_socket_arg} \
${accuracy_only_arg} \
${benchmark_only_arg} \
${verbose_arg}"

# Add on --in-graph and --data-location for int8 inference
if [ ${MODE} == "inference" ] && [ ${PLATFORM} == "int8" ]; then
    CMD="${CMD} --in-graph=${IN_GRAPH} --data-location=${DATASET_LOCATION}"
fi

function install_protoc() {
  # install protoc, if necessary, then compile protoc files
  if [ ! -f "bin/protoc" ]; then
    install_location=$1
    echo "protoc not found, installing protoc from ${install_location}"
    apt-get -y install wget
    wget -O protobuf.zip ${install_location}
    unzip -o protobuf.zip
    rm protobuf.zip
  else
    echo "protoc already found"
  fi

}

# DeepSpeech model
function deep-speech() {
  if [ ${PLATFORM} == "fp32" ]; then
    if [[ -z "${datafile_name}" ]]; then
      echo "DeepSpeech requires -- datafile_name arg to be defined"
      exit 1
    fi

    pip install -r "${MOUNT_BENCHMARK}/speech_recognition/tensorflow/deep-speech/requirements.txt"
    export PYTHONPATH=${PYTHONPATH}:${MOUNT_EXTERNAL_MODELS_SOURCE}
    apt-get install swig libsox-dev -y
    
    build_whls=true
    # If whl exists and older than 1 day, install existing whl files
    if ls ${MOUNT_EXTERNAL_MODELS_SOURCE}/DeepSpeech/native_client/ctcdecode/dist/*whl 1> /dev/null 2>&1 &&
       ls ${MOUNT_EXTERNAL_MODELS_SOURCE}/DeepSpeech/native_client/python/dist/*whl 1> /dev/null 2>&1
    then
      deepspeech_whl=$(ls ${MOUNT_EXTERNAL_MODELS_SOURCE}/DeepSpeech/native_client/ctcdecode/dist/*whl)
      decoder_whl=$(ls ${MOUNT_EXTERNAL_MODELS_SOURCE}/DeepSpeech/native_client/python/dist/*whl)
      touch -d '1 days ago' 1_day_ago
      if [ ! $deepspeech_whl -ot 1_day_ago ]; then
        pip install -I $deepspeech_whl
        pip install -I $decoder_whl
        build_whls=false 
      fi
      rm ./1_day_ago 
    fi

    if [ "$build_whls" = true ]; then
      original_dir=$(pwd)
      # remove untracked files in model source directory so that it doesnt
      # interfere with bazel & decoder build
      cd ${MOUNT_EXTERNAL_MODELS_SOURCE}/DeepSpeech && git clean -fd && cd  ..
      export build_dir="$PWD/mozilla-build"
      export TFDIR="$PWD/tensorflow/"
      cd tensorflow
      ln -s ${MOUNT_EXTERNAL_MODELS_SOURCE}/DeepSpeech/native_client .
      \r | ./configure
      bazel --output_base=$build_dir build --config=monolithic -c opt --copt -D_GLIBCXX_USE_CXX11_ABI=0 \
          --copt -mfma --copt -mavx2 --copt -march=broadwell --copt=-O3 --copt=-fvisibility=hidden \
          //native_client:libdeepspeech.so //native_client:generate_trie
      cd ${MOUNT_EXTERNAL_MODELS_SOURCE}/DeepSpeech/native_client
      make deepspeech
      PREFIX=/usr/local make install
      cd ./python/
      make bindings
      pip install --upgrade dist/deepspeech*.whl
      cd ../ctcdecode
      make bindings NUM_PROCESSES=8
      pip install -I dist/*.whl
      cd $original_dir
    fi
    CMD="${CMD} --checkpoint=${CHECKPOINT_DIRECTORY} \
    --data-location=${DATASET_LOCATION} \
    --datafile-name=${datafile_name}"
    PYTHONPATH=${PYTHONPATH} CMD=${CMD} run_model
  else
      echo "MODE:${MODE} and PLATFORM=${PLATFORM} not supported"
  fi
}

# Fast R-CNN (ResNet50) model
function fastrcnn() {
    if [ ${PLATFORM} == "fp32" ]; then
        if [[ -z "${config_file}" ]]; then
            echo "Fast R-CNN requires -- config_file arg to be defined"
            exit 1
        fi
        # install dependencies
        pip install -r "${MOUNT_BENCHMARK}/object_detection/tensorflow/fastrcnn/requirements.txt"
        original_dir=$(pwd)
        cd "${MOUNT_EXTERNAL_MODELS_SOURCE}/research"
        # install protoc v3.3.0, if necessary, then compile protoc files
        install_protoc "https://github.com/google/protobuf/releases/download/v3.3.0/protoc-3.3.0-linux-x86_64.zip"
        echo "Compiling protoc files"
        ./bin/protoc object_detection/protos/*.proto --python_out=.

        export PYTHONPATH=$PYTHONPATH:`pwd`:`pwd`/slim
        # install cocoapi
        cd ${MOUNT_EXTERNAL_MODELS_SOURCE}/cocoapi/PythonAPI
        echo "Installing COCO API"
        make
        cp -r pycocotools ${MOUNT_EXTERNAL_MODELS_SOURCE}/research/
        export PYTHONPATH=${PYTHONPATH}:${MOUNT_EXTERNAL_MODELS_SOURCE}

        cd $original_dir
        CMD="${CMD} --checkpoint=${CHECKPOINT_DIRECTORY} \
        --data-location=${DATASET_LOCATION} \
        --config_file=${config_file}"

        PYTHONPATH=${PYTHONPATH} CMD=${CMD} run_model
     else
        echo "PLATFORM=${PLATFORM} is not supported for ${MODEL_NAME}"
        exit 1
    fi
}

# inceptionv3 model
function inceptionv3() {
  if [ ${PLATFORM} == "int8" ]; then
    # For accuracy, dataset location is required, see README for more information.
    if [ ! -d "${DATASET_LOCATION}" ] && [ ${ACCURACY_ONLY} == "True" ]; then
      echo "No Data directory specified, accuracy will not be calculated."
      exit 1
    fi

    export PYTHONPATH=${PYTHONPATH}:${MOUNT_EXTERNAL_MODELS_SOURCE}
    input_height_arg=""
    input_width_arg=""

    if [ -n "${input_height}" ]; then
      input_height_arg="--input-height=${input_height}"
    fi

    if [ -n "${input_width}" ]; then
      input_width_arg="--input-width=${input_width}"
    fi

    CMD="${CMD} ${input_height_arg} ${input_width_arg}"
    PYTHONPATH=${PYTHONPATH} CMD=${CMD} run_model

  elif [ ${PLATFORM} == "fp32" ]; then
    # Run inception v3 fp32 inference with dummy data no --data-location is required
    CMD="${CMD} --in-graph=${IN_GRAPH}"
    PYTHONPATH=${PYTHONPATH} CMD=${CMD} run_model

  else
    echo "PLATFORM=${PLATFORM} is not supported for ${MODEL_NAME}"
    exit 1
  fi
}

# NCF model
function ncf() {
  if [ ${PLATFORM} == "fp32" ]; then
    # For nfc, if dataset location is empty, script downloads dataset at given location.
    if [ ! -d "${DATASET_LOCATION}" ]; then
      mkdir -p /dataset
    fi

    export PYTHONPATH=${PYTHONPATH}:${MOUNT_EXTERNAL_MODELS_SOURCE}
    pip install -r ${MOUNT_EXTERNAL_MODELS_SOURCE}/official/requirements.txt

    CMD="${CMD} --checkpoint=${CHECKPOINT_DIRECTORY} \
    --data-location=${DATASET_LOCATION}"

    PYTHONPATH=${PYTHONPATH} CMD=${CMD} run_model
  else
    echo "PLATFORM=${PLATFORM} is not supported for ${MODEL_NAME}"
    exit 1
  fi
}

# ResNet101 model
function resnet101() {
    export PYTHONPATH=${PYTHONPATH}:$(pwd):${MOUNT_BENCHMARK}

    # For accuracy, dataset location is required.
    if [ "${DATASET_LOCATION_VOL}" == "None" ] && [ ${ACCURACY_ONLY} == "True" ]; then
      echo "No Data directory specified, accuracy will not be calculated."
      exit 1
    fi

    if [ ${PLATFORM} == "fp32" ]; then
      CMD="${CMD} --in-graph=${IN_GRAPH} --data-location=${DATASET_LOCATION}"
      PYTHONPATH=${PYTHONPATH} CMD=${CMD} run_model
    else
      echo "PLATFORM=${PLATFORM} is not supported for ${MODEL_NAME}"
      exit 1
    fi
}

# Resnet50 int8 and fp32 models
function resnet50() {
    export PYTHONPATH=${PYTHONPATH}:$(pwd):${MOUNT_BENCHMARK}

    if [ ${PLATFORM} == "int8" ]; then
        # For accuracy, dataset location is required, see README for more information.
        if [ "${DATASET_LOCATION_VOL}" == None ] && [ ${ACCURACY_ONLY} == "True" ]; then
          echo "No Data directory specified, accuracy will not be calculated."
          exit 1
        fi
        PYTHONPATH=${PYTHONPATH} CMD=${CMD} run_model

    elif [ ${PLATFORM} == "fp32" ]; then
        # Run resnet50 fp32 inference
        CMD="${CMD} --in-graph=${IN_GRAPH} --data-location=${DATASET_LOCATION}"
        PYTHONPATH=${PYTHONPATH} CMD=${CMD} run_model
    else
        echo "PLATFORM=${PLATFORM} is not supported for ${MODEL_NAME}"
        exit 1
    fi
}

# R-FCN (ResNet101) model
function rfcn() {
    # install dependencies
    pip install -r "${MOUNT_BENCHMARK}/object_detection/tensorflow/rfcn/requirements.txt"
    original_dir=$(pwd)

    cd "${MOUNT_EXTERNAL_MODELS_SOURCE}/research"
    # install protoc v3.3.0, if necessary, then compile protoc files
    install_protoc "https://github.com/google/protobuf/releases/download/v3.3.0/protoc-3.3.0-linux-x86_64.zip"
    echo "Compiling protoc files"
    ./bin/protoc object_detection/protos/*.proto --python_out=.

    export PYTHONPATH=$PYTHONPATH:`pwd`:`pwd`/slim:${MOUNT_EXTERNAL_MODELS_SOURCE}
    # install cocoapi
    cd ${MOUNT_EXTERNAL_MODELS_SOURCE}/cocoapi/PythonAPI
    echo "Installing COCO API"
    make
    cp -r pycocotools ${MOUNT_EXTERNAL_MODELS_SOURCE}/research/

    if [ ${PLATFORM} == "int8" ]; then
        number_of_steps_arg=""
        split_arg=""

        if [ -n "${number_of_steps}" ] && [ ${BENCHMARK_ONLY} == "True" ]; then
            number_of_steps_arg="--number_of_steps=${number_of_steps}"
        fi

        if [ -n "${split}" ] && [ ${ACCURACY_ONLY} == "True" ]; then
            split_arg="--split=${split}"
        fi

        CMD="${CMD} ${number_of_steps_arg} ${split_arg}"

    elif [ ${PLATFORM} == "fp32" ]; then
        if [[ -z "${config_file}" ]]; then
            echo "R-FCN requires -- config_file arg to be defined"
            exit 1
        fi

        CMD="${CMD} --checkpoint=${CHECKPOINT_DIRECTORY} \
        --config_file=${config_file} --data-location=${DATASET_LOCATION}"
     else
        echo "MODE:${MODE} and PLATFORM=${PLATFORM} not supported"
    fi
    cd $original_dir
    PYTHONPATH=${PYTHONPATH} CMD=${CMD} run_model
}

# SqueezeNet model
function squeezenet() {
  if [ ${PLATFORM} == "fp32" ]; then
    CMD="${CMD} --checkpoint=${CHECKPOINT_DIRECTORY} \
    --data-location=${DATASET_LOCATION}"

    PYTHONPATH=${PYTHONPATH} CMD=${CMD} run_model
  else
    echo "PLATFORM=${PLATFORM} is not supported for ${MODEL_NAME}"
    exit 1
  fi
}

# SSD-MobileNet model
function ssd_mobilenet() {
  if [ ${PLATFORM} == "fp32" ]; then
    # install dependencies
    pip install -r "${MOUNT_BENCHMARK}/object_detection/tensorflow/ssd-mobilenet/requirements.txt"

    original_dir=$(pwd)
    cd "${MOUNT_EXTERNAL_MODELS_SOURCE}/research"

    if [ ${BATCH_SIZE} != "-1" ]; then
      echo "Warning: SSD-MobileNet inference script does not use the batch_size arg"
    fi

    # install protoc, if necessary, then compile protoc files
    install_protoc "https://github.com/google/protobuf/releases/download/v3.0.0/protoc-3.0.0-linux-x86_64.zip"

    echo "Compiling protoc files"
    ./bin/protoc object_detection/protos/*.proto --python_out=.

    export PYTHONPATH=$PYTHONPATH:$(pwd):$(pwd)/slim

    cd $original_dir

    CMD="${CMD} --in-graph=${IN_GRAPH} \
    --data-location=${DATASET_LOCATION}"
    CMD=${CMD} run_model
  else
    echo "PLATFORM=${PLATFORM} is not supported for ${MODEL_NAME}"
    exit 1
  fi
}

# Wavenet model
function wavenet() {
  if [ ${PLATFORM} == "fp32" ]; then
    export PYTHONPATH=${PYTHONPATH}:${MOUNT_EXTERNAL_MODELS_SOURCE}

    pip install -r ${MOUNT_EXTERNAL_MODELS_SOURCE}/requirements.txt

    if [[ -z "${checkpoint_name}" ]]; then
      echo "wavenet requires -- checkpoint_name arg to be defined"
      exit 1
    fi

    if [[ -z "${sample}" ]]; then
      echo "wavenet requires -- sample arg to be defined"
      exit 1
    fi

    CMD="${CMD} --checkpoint=${CHECKPOINT_DIRECTORY} \
        --checkpoint_name=${checkpoint_name} \
        --sample=${sample}"

    PYTHONPATH=${PYTHONPATH} CMD=${CMD} run_model
  else
    echo "PLATFORM=${PLATFORM} is not supported for ${MODEL_NAME}"
    exit 1
  fi
}

# Wide & Deep model
function wide_deep() {
    if [ ${PLATFORM} == "fp32" ]; then
        # install dependencies
        pip install -r "${MOUNT_BENCHMARK}/classification/tensorflow/wide_deep/requirements.txt"
        export PYTHONPATH=${PYTHONPATH}:${MOUNT_EXTERNAL_MODELS_SOURCE}

        CMD="${CMD} --checkpoint=${CHECKPOINT_DIRECTORY} \
        --data-location=${DATASET_LOCATION}"
        CMD=${CMD} run_model
    else
        echo "PLATFORM=${PLATFORM} not supported for ${MODEL_NAME}"
        exit 1
    fi
}

LOGFILE=${LOG_OUTPUT}/${LOG_FILENAME}
echo "Log output location: ${LOGFILE}"

MODEL_NAME=$(echo ${MODEL_NAME} | tr 'A-Z' 'a-z')
if [ ${MODEL_NAME} == "deep-speech" ]; then
  deep-speech
elif [ ${MODEL_NAME} == "fastrcnn" ]; then
  fastrcnn
elif [ ${MODEL_NAME} == "inceptionv3" ]; then
  inceptionv3
elif [ ${MODEL_NAME} == "ncf" ]; then
  ncf
elif [ ${MODEL_NAME} == "resnet101" ]; then
  resnet101
elif [ ${MODEL_NAME} == "resnet50" ]; then
  resnet50
elif [ ${MODEL_NAME} == "rfcn" ]; then
  rfcn
elif [ ${MODEL_NAME} == "squeezenet" ]; then
  squeezenet
elif [ ${MODEL_NAME} == "ssd-mobilenet" ]; then
  ssd_mobilenet
elif [ ${MODEL_NAME} == "wavenet" ]; then
  wavenet
elif [ ${MODEL_NAME} == "wide_deep" ]; then
  wide_deep
else
  echo "Unsupported model: ${MODEL_NAME}"
  exit 1
fi