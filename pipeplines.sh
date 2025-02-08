#!/usr/bin/env bash

# Example Usage:
# ./pipelines.sh Org1 Proj1 start pipeline1,pipeline2,pipeline3
# ./pipelines.sh Org1 Proj1 start pipelinex-*
# ./pipelines.sh Org1 Proj1 approve pipeline1 test
# ./pipelines.sh Org1 Proj1 approve pipelinex-* test

#input
echo $1 | grep -E -q '^[a-zA-Z0-9\-]+$' || { echo "Parameter #1 org not provided"; exit 1; }
org=$1

echo $2 | grep -E -q '^[a-zA-Z0-9\-]+$' || { echo "Parameter #2 project not provided"; exit 1; }
project=$2

echo $3 | grep -E -q '^[a-zA-Z0-9,\*\-]+$' || { echo "Parameter #3 pipelines not provided"; exit 1; }
pipelines=$3

echo $4 | grep -E -q '^start|approve$' || { echo "Parameter #4 action not provided"; exit 1; }
action=$4

echo $5 | grep -E -q '^[0-9]+$' || { echo "Parameter #5 env not provided"; exit 1; }
env=$5

if [[ $action == "approve" && $env == "" ]]; then
    echo "Parameter #5 env must be provided if action = approve"
    exit 1
fi

IFS=', ' read -r -a pipelines <<< "$pipelines"

echo "action=$action"
echo "pipelines=${pipelines[@]}"
echo "env=$env"

adoBaseUrl="https://dev.azure.com/$org/$project/_apis"
resource="https://management.core.windows.net/"

for pipeline in "${pipelines[@]}"; do
    echo "Applying action $action to pipeline (mask) $pipeline ..."

    # find pipeline id
    if [[ $pipeline == *"*" ]]; then
        # if pipeline ends with * then create an array of pipelineIds
        pipeline=$(echo $pipeline | sed 's/\*//g')
        pipelineIdNamesTemp=$(az rest --uri "$adoBaseUrl/pipelines?api-version=7.1" --resource $resource | jq -r ".value.[] | select( .name | startswith(\"$pipeline\")) | \"\(.id),\(.name)\" | @sh")
        declare -a pipelineIdNames="($pipelineIdNamesTemp)"
    else
        pipelineIdNamesTemp=$(az rest --uri "$adoBaseUrl/pipelines?api-version=7.1" --resource $resource | jq -r ".value.[] | select( .name == \"$pipeline\" ) | \"\(.id),\(.name)\" | @sh")
        declare -a pipelineIdNames="($pipelineIdNamesTemp)"
    fi
    # echo "pipelineIdNames=${pipelineIdNames[@]}"

    echo "Are you sure you want to apply action $action (for env $env) to below pipeline(s)? (y/n)"
    printf '%s\n' "${pipelineIdNames[@]}"
    read -r response
    if [[ $response != "y" ]]; then
        echo "Exiting ..."
        exit 1
    fi
.
    for pipelineIdName in "${pipelineIdNames[@]}"; do
        # echo "pipelineIdName=$pipelineIdName"

        IFS=',' read -ra pipelineIdName2 <<< "$pipelineIdName"

        pipelineId=${pipelineIdName2[0]}
        pipelineName=${pipelineIdName2[1]}

        if [[ $action == "start" ]]; then
            echo "Starting pipeline with id $pipelineId and name $pipelineName ..."

            az rest --method POST --uri "$adoBaseUrl/pipelines/$pipelineId/runs?api-version=7.1" --resource $resource --body "{}" > /dev/null

            echo "Pipeline with id $pipelineId and name $pipelineName started"

        elif [[ $action == "approve" ]]; then
            echo "Approving $env deployment for pipeline with id $pipelineId and name $pipelineName ..."

            pipelineId=$(az rest --uri "$adoBaseUrl/pipelines?api-version=7.1" --resource $resource | jq -c ".value.[] | select( .name == \"$pipeline\" ).id")
            # echo "pipelineId=$pipelineId"

            # find last build, timeline
            build=$(az rest --uri "$adoBaseUrl/build/builds?api-version=7.1&definitions=$pipelineId&queryOrder=startTimeDescending&\$top=1" --resource $resource)
            buildId=$(echo $build | jq -r '.value[0].id')
            # echo "buildId=$buildId"
            timelineUrl=$(echo $build | jq -r '.value[0]._links.timeline.href')
            # echo "timelineUrl=$timelineUrl"

            timeline=$(az rest --uri "$timelineUrl" --resource $resource)

            # find record with identifier "Deploy_test3" && type "Stage" => recordId

            # WARNING: The assumption is that the deploy stage record identifier is constructed as "Deploy_$env". If not, this logic needs to be updated
            deployStageRecordIdentifier="Deploy_$env"
            # echo "deployStageRecordIdentifier=$deployStageRecordIdentifier"

            deployStageRecordId=$(echo $timeline | jq -r ".records[] | select( .identifier == \"$deployStageRecordIdentifier\" and .type == \"Stage\" ).id")
            # echo "deployStageRecordId=$deployStageRecordId"

            # find record with parentId§ == recordId && type "Checkpoint" => recordId2
            checkpointRecordId=$(echo $timeline | jq -r ".records[] | select( .parentId == \"$deployStageRecordId\" and .type == \"Checkpoint\" ).id")
            # echo "checkpointRecordId=$checkpointRecordId"

            # find record with parentId == recordId2 && type "Checkpoint.Approval" => appovalId
            approvalId=$(echo $timeline | jq -r ".records[] | select( .parentId == \"$checkpointRecordId\" and .type == \"Checkpoint.Approval\" ).id")

            approvalStatus=$(az rest --uri "$adoBaseUrl/pipelines/approvals/$approvalId?api-version=7.1" --resource $resource | jq -r ".status")

            if [[ $approvalStatus != "pending" ]]; then
                echo "Approval $approvalId for stage $deployStageRecordIdentifier for pipeline $pipeline not pending but $approvalStatus, skipping ..."
            else
                echo "Approving stage $deployStageRecordIdentifier for pipeline $pipeline ..."
                az rest --method PATCH --uri "$adoBaseUrl/pipelines/approvals?api-version=7.1" \
                    --resource $resource \
                    --body "[ { \"approvalId\":\"$approvalId\", \"comment\":\"cli\", \"status\":\"approved\" } ]"
                echo "Stage $deployStageRecordIdentifier for pipeline $pipeline approved"
            fi

        fi

    done

done
