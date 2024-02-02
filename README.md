# NudgeUpdateConfigProfile

## Introduction
Many macOS Systems Administrators have turned to [Nudge](https://github.com/macadmins/nudge) for keeping macOS up-to-date on client systems. Nudge has a potential drawback for busy admins and those desiring granular control of which users are required to install updates and when said updates must be installed.

For every release of macOS, the requiredMinimumVersion and requiredInstallationDate preferences must be updated. This is quick if you have one configuration to manage and/or your organization requires a single version of macOS. This process can become cumbersome if you patch in phases (Pilot Users, Regular Users, VIP) and/or support multiple versions of macOS.

NudgeUpdateConfigProfile is a script that automates setting the requiredMinimumVersion and requiredInstallationDate preferences in a Configuration Profile, deployed by Jamf. The script pulls the latest macOS versions from Apple[^1] and updates your Nudge Configuration Profile(s) in Jamf, with those versions, based on the Nudge targetOSVersionRule and sets a new requiredInstallation date of your choosing. If the requiredMinimumVersions have not changed, the script exits. You can run this script manually or set up a LaunchDaemon to schedule runs.

[^1]: A huge thanks to the developers of [mist-cli](https://github.com/ninxsoft/mist-cli) for inspiration on querrying the Apple SoftwareUpdateCatalog.

## Requirements
- A mac of some sort to run the script.
  - The script is written in zsh and I suggest using a LaunchDaemon for scheduling. You are welcome to modify this script for another shell if it suites your needs.
- [XMLStarlet](https://xmlstar.sourceforge.net/)
  - Used to replace the payloads node.
- A Jamf API Role and Client configured with Configuration Profile Read/Modify persmissions
- The names of Jamf Configuration Profiles configured for Nudge
- Customization of the variables at the top of the script

## Running the Script
The script takes pairs of arguments, where the first argument is the name of the Configuration Profile and the second argument is the amount of days, weeks, years(?) in the future you want to set as the requiredInstallation date. You can provide the script with as many pairs of arguments as needed.
- Example 1: `sudo ./NudgeUpdateConfigProfile.sh "ConfigProfileName1" "2w"`
- Example 2: `sudo ./NudgeUpdateConfigProfile.sh "ConfigProfileName1" "2w" "ConfigProfileName2" "3w"`
- Example 2: `sudo ./NudgeUpdateConfigProfile.sh "ConfigProfileName1" "6d" "ConfigProfileName2" "2w" "ConfigProfileName3" "3w"`

An even better way to go about this is setting up a LaunchDaemon to run the script on a schedule for you.

## Setting up a LaunchDaemon to run the script on a schedule *(optional)*
Customize the ExampleLaunchDaemon.plist file in this repo as follows.

1. Replace `com.organization` with whatever identifer suites your organization.
```
<key>Label</key>
<string>com.organization.NudgeUpdateConfigProfile</string>
```
2. Set the program arguments (delete argument pairs as needed)
  - 1st string = the script path
  - strings 2 and 3 = the first pair of arguments for the script (see Running the Script above)
  - strings 4 and 5 = the second pair of arguments for the script (see Running the Script above)
  - strings 6 and 6 = the third pair of arguments for the script (see Running the Script above)

```
<key>ProgramArguments</key>
<array>
	<string>/usr/local/bin/NudgeUpdateConfigProfile.sh</string>
	<string>Configuration Profile Name 1</string>
	<string>-2w</string>
	<string>Configuration Profile Name 2</string>
	<string>-4w</string>
	<string>Configuration Profile Name 3</string>
	<string>-6w</string>
</array>
```
3. Set the schedule with StartCalendarInterval. In this example, the script will run on Tuesdays at 10am local time.
```
<key>StartCalendarInterval</key>
<dict>
	<key>Hour</key>
	<integer>10</integer>
	<key>Weekday</key>
	<integer>2</integer>
</dict>
```
4. Move the script to the path you set in the LaunchDaemon and set ownership to root:wheel `sudo chown root:wheel /usr/local/bin/NudgeUpdateConfigProfile.sh`
5. Rename the LaunchDaemon to the label you set in the LaunchDaemon, move to `/Library/LaunchDaemons/` and set the ownership to root:wheel `sudo chown root:wheel /Library/LaunchDaemons/com.organization.NudgeUpdateConfigProfile.plist`
6. Load the LaunchDaemon with `cd /Library/LaunchDaemons && sudo launchctl load com.organization.NudgeUpdateConfigProfile.plist`
