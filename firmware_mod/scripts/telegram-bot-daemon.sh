#!/bin/sh

 . /system/sdcard/scripts/common_functions.sh

CURL="/system/sdcard/bin/curl"
LASTUPDATEFILE="/tmp/last_update_id"
TELEGRAM="/system/sdcard/bin/telegram"
JQ="/system/sdcard/bin/jq"
CUSTOMSCRIPT="/system/sdcard/scripts/telegramCustomScript.sh"

. /system/sdcard/config/telegram.conf
[ -z $apiToken ] && echo "api token not configured yet" && exit 1
[ -z $userChatId ] && echo "chat id not configured yet" && exit 1
echo 0 > $lastSentUpdate 

sendShot() {
  /system/sdcard/bin/getimage > "/tmp/telegram_image.jpg" &&\
  $TELEGRAM p "/tmp/telegram_image.jpg"
  rm "/tmp/telegram_image.jpg"
}

sendMem() {
  $TELEGRAM m $(free -k | awk '/^Mem/ {print "Mem: used "$3" free "$4} /^Swap/ {print "Swap: used "$3}')
}

nightOn() {
  night_mode on && $TELEGRAM m "Night mode active"
}

nightOff() {
  night_mode off && $TELEGRAM m "Night mode inactive"
}

detectionOn() {
  rewrite_config /system/sdcard/config/motion.conf send_telegram "true" && $TELEGRAM m "Motion detection started"
}

detectionOff() {
  rewrite_config /system/sdcard/config/motion.conf send_telegram "false" && $TELEGRAM m "Motion detection stopped"
}

textAlerts() {
  rewrite_config /system/sdcard/config/motion.conf telegram_alert_type "text"
  $TELEGRAM m "Text alerts on motion detection enabled"
}

imageAlerts() {
  rewrite_config /system/sdcard/config/motion.conf telegram_alert_type "image"
  $TELEGRAM m "Image alerts on motion detection enabled"
}

videoAlerts() {
  rewrite_config /system/sdcard/config/motion.conf telegram_alert_type "video"
  $TELEGRAM m "Video alerts on motion detection enabled"
}

setInterval() {
  if [ "$1" -ge 0 ] ; then
    rewrite_config /system/sdcard/config/telegram.conf telegramInterval $1
    $TELEGRAM m "Interval set to $1 seconds" 
  else 
    $TELEGRAM m "Invalid input: $1" 
  fi
}

setTargetChat() {
  rewrite_config /system/sdcard/config/telegram.conf userChatId \"$1\"
  $TELEGRAM mu $origUserChatId "Target chat set to $1" 
  $TELEGRAM m "You are the new receiver of updates" 
  . /system/sdcard/config/telegram.conf
}

restoreTargetChat() {
  rewrite_config /system/sdcard/config/telegram.conf userChatId $origUserChatId
  $TELEGRAM m "Target chat set to origin"
  . /system/sdcard/config/telegram.conf
}

customScript() {
  $CUSTOMSCRIPT $1 & $TELEGRAM m "Started custom script" 
}

respond() {
  cmd=$1
  [ $chatId -lt 0 ] && cmd=${1%%@*}
  case $cmd in
    /mem) sendMem;;
    /shot) sendShot;;
    /on) detectionOn;;
    /off) detectionOff;;
    /nighton) nightOn;;
	  /nightoff) nightOff;;
	  /textalerts) textAlerts;;
    /imagealerts) imageAlerts;;
	  /videoalerts) videoAlerts;;
    /interval) setInterval $2;;
    /script) customScript $2;;
    /setchat) setTargetChat $2;;
    /restorechat) restoreTargetChat;;
    /help | /start) $TELEGRAM m "######### Bot commands #########\n# /mem - show memory information\n# /shot - take a shot\n# /on - motion detect on\n# /off - motion detect off\n# /nighton - night mode on\n# /nightoff - night mode off\n# /textalerts - Text alerts on motion detection\n# /imagealerts - Image alerts on motion detection\n# /videoalerts - Video alerts on motion detection\n# /interval N - Set time frame to send alerts\n# /script - Execute custom script\n# /setchat N - Set new chat for messages\n# /restorechat - Restore original chat for messages";;
    *) $TELEGRAM m "I can't respond to '$cmd' command"
  esac
}

readNext() {
  lastUpdateId=$(cat $LASTUPDATEFILE || echo "0")
  json=$($CURL -s -X GET "https://api.telegram.org/bot$apiToken/getUpdates?offset=$lastUpdateId&limit=1&allowed_updates=message")
  echo $json
}

markAsRead() {
  nextId=$(($1 + 1))
  echo "$nextId" > $LASTUPDATEFILE
}

main() {
  json=$(readNext)

  [ -z "$json" ] && return 0
  if [ "$(echo "$json" | $JQ -r '.ok')" != "true" ]; then
	echo "$(date '+%F %T') Bot error: $json" >> /tmp/telegram.log
	[ "$(echo "$json" | $JQ -r '.error_code')" == "401" ] && return 1
	return 0
  fi;

  messageAttr="message"
  messageVal=$(echo "$json" | $JQ -r ".result[0].$messageAttr // \"\"")
  [ -z "$messageVal" ] && messageAttr="edited_message"

  messageEdit=$(echo "$json" | $JQ -r ".result[0].$messageAttr // \"\"")
  [ -z "$messageEdit" ] && messageAttr="channel_post"

  messagePost=$(echo "$json" | $JQ -r ".result[0].$messageAttr // \"\"")
  [ -z "$messagePost" ] && return 0 # update type not supported

  #messageVal=$(echo "$json" | $JQ -r '.result[0].message // ""')
  #[ -z "$messageVal" ] && messageAttr="edited_message" && messageVal=$(echo "$json" | $JQ -r '.result[0].edited_message // ""')
  #[ -z "$messageVal" ] && messageAttr="channel_post"
  chatId=$(echo "$json" | $JQ -r ".result[0].$messageAttr.chat.id // \"\"")
  updateId=$(echo "$json" | $JQ -r '.result[0].update_id // ""')
  if [ "$updateId" != "" ] && [ -z "$chatId" ]; then
  markAsRead $updateId
  return 0
  fi;

  [ -z "$chatId" ] && return 0 # no new messages

  cmd=$(echo "$json" | $JQ -r ".result[0].$messageAttr.text // \"\"")

  if [ "$chatId" != "$userChatId" ] && [ "$chatId" != "$origUserChatId" ]; then
    username=$(echo "$json" | $JQ -r ".result[0].$messageAttr.from.username // \"\"")
    firstName=$(echo "$json" | $JQ -r ".result[0].$messageAttr.from.first_name // \"\"")
    $TELEGRAM m "Received message from unauthorized chat id: $chatId\nUser: $username($firstName)\nMessage: $cmd"
  elif [ "$userChatId" != "$origUserChatId" ] && [ "$chatId" == "$origUserChatId" ]; then
    p=${cmd%%@*}
    if [ "$p" == "/restorechat" ]; then
      respond $cmd
    else
      $TELEGRAM mu $origUserChatId "Restore target chat with /restorechat before using this command.\nCurrent chat is $userChatId"
    fi;
  else
	respond $cmd
  fi;

  markAsRead $updateId
}

while true; do
  main >/dev/null 2>&1
  [ $? -gt 0 ] && exit 1
  sleep 5
done;
