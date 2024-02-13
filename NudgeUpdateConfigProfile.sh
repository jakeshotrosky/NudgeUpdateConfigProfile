#!/bin/zsh

######################################################################################################
######################################################################################################
###
###             Name:       NudgeUpdateConfigProfile
###
###             Author:     Jake Shotrosky
###             Purpose:    Update Nudge Configuration Profiles wih the latest macOS versions from
###                         Apple and set new requiredInstallationDates. If the macOS versions in the
###                         Configuration Profiles have not changed, do not update the profile.
###             Usage:      Run the script and provide pairs of arguments, where argument 1 is the 
###                         name of a Configuration Profile and argument 2 is the desired deadline
###                         in #(d|w) format (2w = two weeks from today)
###                         --Example 1: ./NudgeUpdateConfigProfile.sh "ConfigProfileName1" "2w" 
###                         --Example 2: ./NudgeUpdateConfigProfile.sh "ConfigProfileName1" "2w" "CPN2" "4w"
###                         Logs are saved /var/log/
###             Required:   -A Jamf API Role with Read/Modify persmissions for macOS Configuration
###                         profiles and an API client with that role.
###                         -The names of the configuration profiles you wish to update.
###                         -Customize the Organization related variables.
###                         -For full automation of this script, please customize and load the example
###                         LaunchDaemon in this repo.
###             Updated:    2024/02/01
###
######################################################################################################
######################################################################################################

######################################################################################################
###
###      VARIABLES
###
######################################################################################################

######################################################################################################
#          Variables unique to your Organization or System
######################################################################################################
plistDomain=""      # Reverse Domain Name Notation, used for naming your log file
url=""              # URL of your Jamf instance (must include https://)
client_id=""        # Jamf API Client ID
client_secret=""    # Jamf API Client Secret
xmlstarletPath=""   # "/opt/homebrew/bin" if installed via brew

######################################################################################################
#          Variables related to macOS Updates
######################################################################################################
macOSN="14"         # Set this variable to the latest major release version of macOS (N)
macOSN1="13"        # Set this variable to the previous major release version of macOS (N -1)
macOSN2="12"        # Set this variable to the major release version of macOS, two versions back (N -2)
macOSN3="11"        # Set this variable to the major release version of macOS, three versions back (N -3)

###### URL for current Apple SoftwareUpdate Catalog
softwareUpdateCatalogURL="https://swscan.apple.com/content/catalogs/others/index-14-13-12-10.16-10.15-10.14-10.13-10.12-10.11-10.10-10.9-mountainlion-lion-snowleopard-leopard.merged-1.sucatalog"

######################################################################################################
###
###      PREFLIGHT
###
######################################################################################################

###### Set PATH so we can find xmlstarlet
export PATH="$PATH:$xmlstarletPath"

###### Setup $scriptLog file
scriptLog="/var/log/$plistDomain.log"   # Logfile path
if [[ ! -f "${scriptLog}" ]]; then
    touch "${scriptLog}"
fi

###### Require XMLStarlet
if ! [ $(which xmlstarlet) ]; then 
    echo "XMLStarlet is required for this script"
    exit
fi

###### Parameter Validation
if ! [ $(($#%2)) -eq 0 ]; then
        echo 'Invalid Arguments: Script requires pairs of argument.
            -Argument 1: Configuration Profile Name
            -Argument 2: Deadline in #w format (e.g, 2w)
You can use as many pairs following this format as needed'
        exit
fi
declare -g -A argPair
while [ $# -gt 0 ]; do
    arg1=$1
    shift
    arg2=$1
    shift
    argPair[$arg1]=$arg2
done

######################################################################################################
###
###      FUNCTIONS
###
######################################################################################################
logMessage() {              ### echo NUDGECONFIGUPDATE messages tp $scriptlog 
    echo -e "NUDGECONFIGUPDATE: $( date +%Y-%m-%d\ %H:%M:%S ) - ${1}" \
        | tee -a "${scriptLog}"
}

getAccessToken() {          ### Jamf API Client Credential Authotization 
	response=$(curl --silent --location --request POST "${url}/api/oauth/token" \
 	 	--header "Content-Type: application/x-www-form-urlencoded" \
 		--data-urlencode "client_id=${client_id}" \
 		--data-urlencode "grant_type=client_credentials" \
 		--data-urlencode "client_secret=${client_secret}")
 	access_token=$(echo "$response" | plutil -extract access_token raw -)
 	token_expires_in=$(echo "$response" | plutil -extract expires_in raw -)
 	token_expiration_epoch=$(($current_epoch + $token_expires_in - 1))
}

checkTokenExpiration() {    ### Jamf API Client Credential Authotization
 	current_epoch=$(date +%s)
    if [[ token_expiration_epoch -ge current_epoch ]]
    then
        echo "Token valid until the following epoch time: " "$token_expiration_epoch"
    else
        echo "No valid token available, getting new token"
        getAccessToken
    fi
}

invalidateToken() {         ### Jamf API Client Credential Authotization
	responseCode=$(curl -w "%{http_code}" -H "Authorization: Bearer ${access_token}" $url/api/v1/auth/invalidate-token -X POST -s -o /dev/null)
	if [[ ${responseCode} == 204 ]]
	then
		echo "Token successfully invalidated"
		access_token=""
		token_expiration_epoch="0"
	elif [[ ${responseCode} == 401 ]]
	then
		echo "Token already invalid"
	else
		echo "An unknown error occurred invalidating the token"
	fi
}

apiOSXConfigProfile() {     ### curl GET and PUT commands for Jamf API osxconfigurationprofiles endpoint
    if [ -z $1 ]; then
        local response=$(curl --request GET \
            --url $url/JSSResource/osxconfigurationprofiles/name/$(echo $profile|sed -e 's/ /%20/g')\
            --header "Authorization: Bearer $access_token" \
            --header "Content-Type: application/xml")
    else
        local response=$(curl --request PUT \
            --silent \
            --url $url/JSSResource/osxconfigurationprofiles/name/$(echo $profile|sed -e 's/ /%20/g')\
            --header "Authorization: Bearer $access_token" \
            --header "Content-Type: application/xml" \
            --data-binary $1 \
            --write-out "%{http_code}")
        if [[ ${response:(-3)} == "201" ]]; then
            putResponse="success"
        else putResponse="failure"
        fi
        logMessage "Configuration Profile Update Status: $putResponse"
     fi
     echo $response
}

macOSVersionCheck() {          ### Query Apple for the latest versions of macOS
    logMessage "--Curling Apple SoftwareUpdateCatalog--"
    softwareUpdateCatalog=$(curl --silent $softwareUpdateCatalogURL)

    logMessage "Pulling macOS Update Distribution URLs"
    distURLs=$(echo $softwareUpdateCatalog \
        | xmlstarlet sel --net -t -v "//dict[contains(., 'com.apple.pkg.InstallAssistant.macOS')]/dict/string[contains(., 'English.dist')]")
    distArray=("${(@f)$(echo $distURLs)}")

    declare -a versionArray
    logMessage "Pulling version numbers from each Distribution URL"
    for dist in $distArray; do
        versionArray+=($(curl --silent $dist \
            | xmllint --xpath "//key[.='VERSION']/following-sibling::string[1]/text()" -))
    done

    declare -a sortedVersion
    sortedVersion=($(echo $versionArray \
        | tr ' ' '\n' \
        | sort -V))
    ### For each version in the sorted version list, add items that begin with the major version to an array, then select the last item of array
    ### This gets us the current latest version of that major version. We skip this for N-3, because it should be upgraded to N
    for v in ${sortedVersion[@]}; do if [[ $v =~ "$macOSN2" ]]; then macOSArrayN2+=($v); fi; done; latestN2=("${macOSArrayN2[$((${#macOSArrayN2[@]}))]}")
    for v in ${sortedVersion[@]}; do if [[ $v =~ "$macOSN1" ]]; then macOSArrayN1+=($v); fi; done; latestN1=("${macOSArrayN1[$((${#macOSArrayN1[@]}))]}")
    for v in ${sortedVersion[@]}; do if [[ $v =~ "$macOSN" ]]; then macOSArrayN+=($v); fi; done; latestN=("${macOSArrayN[$((${#macOSArrayN[@]}))]}")
    logMessage "Latest versions are: $latestN, $latestN1, $latestN2"

    ### Create an associative array that contains our Target Major Versions and Minimum Required Versions
    declare -g -A NEWversionProperties=(
    [targetVerRule1]="$macOSN"
    [targetVerRule2]="$macOSN1"
    [targetVerRule3]="$macOSN2"
    [targetVerRule4]="$macOSN3"
    [minReqVer1]="$latestN"
    [minReqVer2]="$latestN1"
    [minReqVer3]="$latestN2"
    [minReqVer4]="$latestN"
    )
}

retrieveXML() {                ### GET the Current Config Profile and deal with <> replacement
    logMessage "--Pulling current Configuration Profile--"
    ####### Convert &lt; and &gt; to >< in the Payload XML and save to variable
    originalXML=$(apiOSXConfigProfile)

    modifiedXML=$(echo $originalXML \
        | xmllint --xpath "//payloads/text()" - \
        | sed -e 's/&lt;/</g;s/&gt;/>/g')
}

retrieveOldUpdateInfo() {      ### Pull Target OS Versions and InstallByDate from current Config Profile
    ####### Get requiredInstallationDate from XML
    logMessage "--Getting Old Values--"
    oldInstallByDate=$(echo $modifiedXML \
        | xmllint --xpath "(//key[.='requiredInstallationDate'])[1]/following-sibling::string[1]/text()" -)
    logMessage "oldInstallByDate: $oldInstallByDate"

    ####### Save the osVersionRequirement Dictionaries to a variable and count the total number
    logMessage "Grabbing targetOSRule and minOSVersion from current file"
    OSVERSIONS=$(echo $modifiedXML \
        | xmllint --xpath "//dict/array/dict/dict/dict/array/dict/dict/array/dict" -) 
    ####### Add a dummy root node so xmllint doesn't get cranky
    OSVERSIONS='<documents>'"\n"$OSVERSIONS"\n"'</documents>'
    OSVERSIONSCount=$(echo $modifiedXML \
        | xmllint --xpath "count(//dict/array/dict/dict/dict/array/dict/dict/array/dict)" -)

    ####### Iterate over each dictionaty, saving each pair of requiredMinimumOSVersion and targetOSVersionRule .
    count=$OSVERSIONSCount
    declare -g -A versionProperties
    while [ $count -gt 0 ]; do
        versionProperties[minReqVer$count]="$(echo $OSVERSIONS | xmllint --xpath "//dict[$count]/key[.='requiredMinimumOSVersion']/following-sibling::string[1]/text()" -)"
        versionProperties[targetVerRule$count]="$(echo $OSVERSIONS | xmllint --xpath "//dict[$count]/key[.='targetedOSVersionsRule']/following-sibling::string[1]/text()" -)"
        count=$((count - 1))
    done
}

compareOldNewUpdateInfo() {    ### Compare the OSVersions from old and new. Exit if no change required
    ####### Match up the targetOSVersionRules and update requiredMinimumOSVersion accordingly
    logMessage "--Comparing Old and New Values--"
    noChangeCount=0
    for oldKey oldValue in ${(@kv)versionProperties}; do 
        if [[ $oldKey =~ "targetVerRule" ]]; then
            logMessage "Matching Target Version Rule with: $oldValue"
            for newKey newValue in ${(kv)NEWversionProperties}; do
                if [[ $oldValue =~ $newValue ]]; then 
                    logMessage "Found match"
                    oldSet="${oldKey: -1}" && newSet="${newKey: -1}"
                    ##### If the New Version is the same as the old, add to counter and break this loop
                    if [[ $versionProperties[minReqVer$oldSet] == $NEWversionProperties[minReqVer$newSet] ]]; then
                        (( noChangeCount+=1 ))
                        logMessage "No change in latest version for Target Rule $oldValue"
                        break
                    fi
                    logMessage "Replacing $versionProperties[minReqVer$oldSet] with $NEWversionProperties[minReqVer$newSet] for Target Version Rule $oldValue"
                    modifiedXML=$(echo $modifiedXML \
                    | sed 's,>'"$versionProperties[minReqVer$oldSet]"'<,>'"$NEWversionProperties[minReqVer$newSet]"'<,')
                break
                fi
            done
        fi  
    done

    if [[ $OSVERSIONSCount == $noChangeCount ]]; then
        logMessage "No changes are required"
        continue
    fi
}

updateXML() {                  ### Update the XML, prepare, and send to the Jamf API
    logMessage "--Modifying Payload XML--"
    ####### Get Current Date plus number of weeks set by deafline variable
    newInstallByDate="$(date -j -v+$deadline "+%Y-%m-%d")T10:00:00Z"
    logMessage "newInstallByDate: $newInstallByDate"
    ####### Set the new requiredInstallationDate
    logMessage "Replacing $oldInstallByDate with $newInstallByDate"
    modifiedXML=$(echo $modifiedXML \
        | sed 's,'"$oldInstallByDate"','"$newInstallByDate"',g')
    ####### Change the <> characters back to &lt;/&gt; for Jamf API compatibility
    logMessage "Setting <> characters back to &lt;/&gt; for Jamf API compatibility"
    modifiedXML=$(echo $modifiedXML \
        | sed -e 's/</\&lt;/g;s/>/\&gt;/g')
    ####### Replace the payloads node with out modified XML
    preppedXML=$(echo $originalXML \
        | xmlstarlet ed -u "//payloads" -v $modifiedXML)
}

######################################################################################################
###
###      PROCESSING
###
######################################################################################################
logMessage '///////BEGIN NUDGECONFIGUPDATE////////////////////////////'
macOSVersionCheck
checkTokenExpiration

for profile deadline in ${(@kv)argPair}; do 
    logMessage "-----Working on Profile ID: $profile-----"
    retrieveXML
    retrieveOldUpdateInfo
    compareOldNewUpdateInfo
    updateXML
    apiOSXConfigProfile $preppedXML
done

invalidateToken
logMessage '///////END NUDGECONFIGUPDATE/////////////////////////////'
exit