#!/bin/sh

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

detectionOn() {
  . /system/sdcard/scripts/common_functions.sh
  rewrite_config /system/sdcard/config/motion.conf send_telegram "true" && $TELEGRAM m "Motion detection started"
}

detectionOff() {
  . /system/sdcard/scripts/common_functions.sh
  rewrite_config /system/sdcard/config/motion.conf send_telegram "false" && $TELEGRAM m "Motion detection stopped"
}

textAlerts() {
  . /system/sdcard/scripts/common_functions.sh
  rewrite_config /system/sdcard/config/telegram.conf telegram_alert_type "text"
  $TELEGRAM m "Text alerts on motion detection"
}

imageAlerts() {
  . /system/sdcard/scripts/common_functions.sh
  rewrite_config /system/sdcard/config/telegram.conf telegram_alert_type "image"
  $TELEGRAM m "Image alerts on motion detection"
}

setInterval() {
  . /system/sdcard/scripts/common_functions.sh
  if [ "$1" -ge 0 ] ; then
    rewrite_config /system/sdcard/config/telegram.conf telegramInterval $1
    $TELEGRAM m "Interval set to $1 seconds" 
  else 
    $TELEGRAM m "Invalid input: $1" 
  fi
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
    /textalerts) textAlerts;;
    /imagealerts) imageAlerts;;
    /interval) setInterval $2;;
    /script) customScript $2;;
    /help | /start) $TELEGRAM m "######### Bot commands #########\n# /mem - show memory information\n# /shot - take a shot\n# /on - motion detect on\n# /off - motion detect off\n# /textalerts - Text alerts on motion detection\n# /imagealerts - Image alerts on motion detection\n# /interval N - Set time frame to send alerts\n# /script - Execute custom script";;
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

  chatId=$(echo "$json" | $JQ -r ".result[0].$messageAttr.chat.id // \"\"")
  [ -z "$chatId" ] && return 0 # no new messages

  cmd=$(echo "$json" | $JQ -r ".result[0].$messageAttr.text // \"\"")
  updateId=$(echo "$json" | $JQ -r '.result[0].update_id // ""')

  if [ "$chatId" != "$userChatId" ]; then
    username=$(echo "$json" | $JQ -r ".result[0].$messageAttr.from.username // \"\"")
    firstName=$(echo "$json" | $JQ -r ".result[0].$messageAttr.from.first_name // \"\"")
    $TELEGRAM m "Received message from not authorized chat: $chatId\nUser: $username($firstName)\nMessage: $cmd"
  else
    respond $cmd
  fi;

  markAsRead $updateId
}

while true; do
  main >/dev/null 2>&1
  [ $? -gt 0 ] && exit 1
  sleep 2
done;
