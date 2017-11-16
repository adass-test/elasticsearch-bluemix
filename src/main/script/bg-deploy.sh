
# Identify log levels
VERBOSITY_ERROR=0
VERBOSITY_WARN=1
VERBOSITY_INFO=2
VERBOSITY_DEBUG=3

VERBOSITY_LEVEL=${VERBOSITY_LEVEL:-$VERBOSITY_DEBUG}
# Log the message
LogMsg(){
        local log_level=$1
        logMsg="$2"
        if [ ${VERBOSITY_LEVEL} -ge ${log_level} ]; then
		VERBOSITY_LEVELS=( ERROR WARNING INFO DEBUG )
                echo "["$(date +"%Y/%m/%d %r")"] [${VERBOSITY_LEVELS[$log_level]}]" ${logMsg}
        fi
}


# Log the message with ERROR status
LogError(){
        LogMsg "$VERBOSITY_ERROR" "$@"
}


# Log the message with WARNING status
LogWarn(){
        LogMsg "$VERBOSITY_WARN" "$@"
}


# Log the message with INFO status
LogInfo(){
        LogMsg "$VERBOSITY_INFO" "$@"
}


# Log the message with DEBUG status
LogDebug(){
        LogMsg "$VERBOSITY_DEBUG" "$@"
}

# runCmd -  running command with retry
runCmd(){
    cmd="$1"
    retcode=1
    retry=3
    sleep_time=30s
    while [ ${retcode} -ne 0 ]&&[ ${retry} -gt 0 ]
    do
        eval "${cmd} 2>&1 | tee -a ${CF_CLI_OUTPUT_FILE}"
        retcode=$?

        if [ ${retcode} -ne 0 ]
        then
            retry=$(expr "${retry}" - 1)
            echo "-> Failed attempt"
            if [ ${retry} -gt 0 ]
            then
                LogInfo "--> Will try again in ${sleep_time}."
                sleep ${sleep_time}
            fi
        fi
    done

    if [ ${retcode} -ne 0 ]&&[ ${retry} -eq 0 ]
    then
        LogError "--> ${cmd} failed. rc=$retcode"
        [ "${DEPLOY_NODUMP}" != "true" ] && cat ${CF_CLI_OUTPUT_FILE}
        exit 1
    fi
}

# extract: extract the tar.gz and resulting zip file
extract(){
        LogDebug "Extracting Artifact - ${BM_ARTIFACT}"
        if [ -d ${APP_DIR} ]; then
                rm -rf ${APP_DIR}
        fi
        mkdir -p ${APP_DIR} && chmod -R 777 ${APP_DIR}
        cd ${APP_DIR}
        tar xzf "${BM_ARTIFACT1}"
        cd ${APP_DIR}/payload

        LogDebug "-> file extraction complete."
}

# cf-login - logins to cloud foundry
cf-login() {
	LogInfo "-> cf-login"
	runCmd "${CF_COMMAND} login \
	-u ${BLUEMIX_ID} \
	-p ${BLUEMIX_PWD} \
	-o ${BLUEMIX_ORG} \
	-s ${BLUEMIX_SPACE} \
	-a ${BM_API_URL_ENDPOINT}"
}

# cf-logout - logouts to cloud foundry
cf-logout() {
	LogInfo "-> cf-logout"
	runCmd "${CF_COMMAND} logout"
}

# cf-app-health-check - check app health / status
cf-app-health-check() {
	local appName=$1
	local app_status=$(${CF_COMMAND} app ${appName} | grep "requested state" | awk -F":" '{print $NF}')
	echo ${app_status}
}

# cf-app-status - check app statu
cf-app-status() {
    local appName=$1
    local app_status=$(cf-app-health-check ${appName})
	if [ "${app_status}" = "stopped" ]; then
		    LogError "${appName} has not pushed properly"
		    LogError "${BM_ARTIFACT} location: ${APP_DIR}"
		    exit 1
	fi
}

# cf-push - Pushes an Application to Cloud Foundry
cf-push() {
	local appName=$1
	local appHost=$2
	
	LogInfo "-> cf-push"
	cd ${APP_DIR}/payload
        runCmd "${CF_COMMAND} push -f ${MANIFEST_PATH}"
	
	cf-app-status ${appName}
}

# cf-delete-app-only - Delete an application from Cloud Foundry
cf-delete-app-only() {
	local appName=$1

	local app_status=$(cf-app-health-check ${appName})
	if [ ! -z "${app_status}" ]; then
		LogInfo "-> cf-delete-app-only"
		runCmd "${CF_COMMAND} delete ${appName} \
		-f"
	fi
}

# cf-delete-app - Delete an application from Cloud Foundry with routes
cf-delete-app() {
	local appName=$1
	local appHost=$2
	
	cf-delete-route ${appHost}
	cf-delete-app-only ${appName}
}

# cf-map-route - Map a route from Cloud Foundry
cf-map-route() {
	local appName=$1
	local appHost=$2
	
	local app_status=$(cf-app-health-check ${appName})
	local route_exists=$(cf-check-route ${appHost} | grep "does exist")
	if [ ! -z "${route_exists}" ]&&[ ! -z "${app_status}" ]; then
	   LogInfo "-> cf-map-route"
	   runCmd "${CF_COMMAND} map-route ${appName} ${BM_DOMAIN} \
	   -n ${appHost}"
	fi
}

# cf-unmap-route - Remove an existing route for an application
cf-unmap-route() {
	local appName=$1
	local appHost=$2
	
	local app_status=$(cf-app-health-check ${appName})
	local route_exists=$(cf-check-route ${appHost} | grep "does exist")
	if [ ! -z "${route_exists}" ]&&[ ! -z "${app_status}" ]; then
	   LogInfo "-> cf-unmap-route"
	   runCmd "${CF_COMMAND} unmap-route ${appName} ${BM_DOMAIN} \
	   -n ${appHost}"
	fi
}

# cf-check-route - check an existing route for an application
cf-check-route() {
	local appName=$1
	LogInfo "-> cf-check-route"
	runCmd "${CF_COMMAND} check-route ${appName} ${BM_DOMAIN}"
}

# cf-delete-route - Delete a route from Cloud Foundry
cf-delete-route() {
	local appHost=$1
	
	local route_exists=$(cf-check-route ${appHost} | grep "does exist")
	if [ ! -z "${route_exists}" ]; then
	    LogInfo "-> cf-delete-route"
	    runCmd "${CF_COMMAND} delete-route ${BM_DOMAIN} \
	    -f \
	    -n ${appHost}"
	fi
}

# cf-create-route - Create route from Cloud Foundry
cf-create-route() {
	local appHost=$1
	
	local route_exists=$(cf-check-route ${appHost} | grep "does exist")
	if [ -z "${route_exists}" ]; then
	    LogInfo "-> cf-create-route"
		runCmd "${CF_COMMAND} create-route ${BLUEMIX_SPACE} \
		${BM_DOMAIN} \
		-n ${appHost}"
	fi
}

# cf-get-app-detail - Get the application detail from Cloud Foundry
cf-get-app-detail() {
	LogInfo "-> cf-get-app-detail"
	runCmd "${CF_COMMAND} apps"
}

# cf-rename-app - Rename an applicaiton
cf-rename-app() {
	local appName=$1
	local newAppName=$2

	local app_status=$(cf-app-health-check ${appName})
	if [ ! -z "${app_status}" ]; then
		LogInfo "-> cf-rename-app ${appName} ${newAppName}"
		runCmd "${CF_COMMAND} rename ${appName} ${newAppName}"
		local app_status=$(cf-app-health-check ${newAppName})
		if [ -z "${app_status}" ]; then
		    LogError "-> Renaming to ${newAppName} FAILED"
		    exit 1
		fi
	fi
}

# cf-restage-app - Restage an Application
cf-restage-app() {
    local appName=$1
    
	LogInfo "-> cf-restage-app"
	runCmd "${CF_COMMAND} restage ${appName}"
}

# cf-stop-app - Stop an Application
cf-stop-app() {
    local appName=$1
    
	LogInfo "-> cf-stop-app"
    runCmd "${CF_COMMAND} stop ${appName}"
}

# cf-start-app - Start an Application
cf-start-app() {
    local appName=$1
    
	LogInfo "-> cf-start-app"
    runCmd "${CF_COMMAND} start ${appName}"
}

# cf-restart-app - Restart an Application
cf-restart-app() {
    local appName=$1
    
	LogInfo "-> cf-restart-app"
    runCmd "${CF_COMMAND} restart ${appName}"
}

# cf-app-validate - Validate Application
cf-app-validate() {
    local appName=$1
    local appHost=$2
	
	cf-app-status ${appName}
	if [ "${BM_APP_ENDPOINT_VALIDATE}" = "true" ]&&[ ! -z "${BM_APP_ENDPOINT}" ]; then
	   LogInfo "-> cf-app-validate: ${appName}"
	   BM_APP_ENDPOINT_URL=https://${appHost}.${BM_DOMAIN}/${BM_APP_ENDPOINT}
	   cf_app_status=$(curl -s ${BM_APP_ENDPOINT_URL} | awk -F"," '{for(i=1;i<=NF;i++) print $(i)}' | grep status | awk -F":" '{print $NF}' | tr -d '"')
       LogInfo "-> ${cf_app_status}"
       if [ "${cf_app_status}" != "ok" ]; then
           LogError "${BM_APP_ENDPOINT_URL} NOT working"
           CF_APP_STATUS=red
       else
           CF_APP_STATUS=green
       fi
    fi
}

# cf-push-blue-green - Push with Blue-Green steps
cf-push-blue-green() {
	local appName=$1
	local appHost=$2
	local newAppName=${appName}-new
	local newAppHost=${newAppName}-${ENVIRONMENT_NAME}
	local oldAppName=${appName}-old
	
	extract

	cf-login
	
	cf-delete-app ${newAppName} ${newAppHost}
	cf-push ${newAppName} ${newAppHost}
	
	cf-app-validate ${newAppName} ${newAppHost}
	if [ "${CF_APP_STATUS}" = "red" ]; then
	    exit 1
	fi
	
	cf-unmap-route ${newAppName} ${newAppHost}
	cf-delete-route ${newAppHost}
	cf-create-route ${appHost}
	cf-map-route ${newAppName} ${appHost}
	cf-rename-app ${appName} ${oldAppName}
	cf-rename-app ${newAppName} ${appName}
	cf-unmap-route ${oldAppName} ${appHost}
	
	cf-app-validate ${appName} ${appHost}
	if [ "${CF_APP_STATUS}" = "green" ]; then
	    # check if app is not processing any requests
	    cf-delete-app-only ${oldAppName}
	else
	    cf-map-route ${oldAppName} ${appHost}
	    cf-rename-app ${appName} ${newAppName}
	    cf-rename-app ${oldAppName} ${appName}
	    cf-unmap-route ${newAppName} ${appHost}
	fi

	cf-logout
}

# delete-app - remove app
delete-app() {
	local appName=$1
	local appHost=$2

	cf-login
	cf-delete-route ${appHost}
	cf-delete-app ${appName}
}

###############            Main starts Here                    ##############
set -o pipefail
SCRIPTPATH=$(pwd)
CF_COMMAND=${SCRIPTPATH}/cf
TIMESTAMP=$(date +"%Y%m%d-%H%M%S")
APP_DIR=${SCRIPTPATH}/APPDIR-${TIMESTAMP}
CF_APP_STATUS=green
BM_ARTIFACT=$1
BLUEMIX_ID=$2
BLUEMIX_PWD=$3
BLUEMIX_ORG=$4
BLUEMIX_SPACE=$5
BM_API_URL_ENDPOINT=$6
MANIFEST_PATH=$7

if [ -z "${CF_COMMAND}" ]; then
	LogError "CF_COMMAND not defined"
	exit 1
fi

if [ -z "${BLUEMIX_ID}" ]; then
	LogError "BLUEMIX_ID not defined"
	exit 1
fi

if [ -z "${BLUEMIX_PWD}" ]; then
	LogError "BLUEMIX_PWD not defined"
	exit 1
fi

if [ -z "${BLUEMIX_ORG}" ]; then
	LogError "BLUEMIX_ORG not defined"
	exit 1
fi

if [ -z "${BLUEMIX_SPACE}" ]; then
	LogError "BLUEMIX_SPACE not defined"
	exit 1
fi

if [ -z "${BM_API_URL_ENDPOINT}" ]; then
	LogError "BM_API_URL_ENDPOINT not defined"
	exit 1
fi

cf-push-blue-green ${BM_APP_NAME} ${BM_APP_HOST}
