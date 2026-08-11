#!/bin/bash


#Настройки
#- - - - - - - - - - - - - - - - - - - - - - - - -

#Локальный TCP сокет, на котором будут ожадататься входящие VNC соединения. При получении VNC соединений они будут перенаправлены на VNС сервер удалённого узла внутри SSH.
fw_vnc_sock=127.0.0.1:55909

#TCP сокет на удалённом компьютере, который будет слушать VNC сервер во время работы. На него внутри SSH будут перенаправлены VNС соединения.
rm_vnc_sock=127.0.0.1:5900

#Команда запуска VNC клиента на локальном узле. Можно использовать любой, который принимает адрес VNC сервера сразу после команды, и не требует интерактивного ввода в командной строке.
vnc_client="xtightvncviewer"

#Сокет pipewire module-native-protocol-tcp на локальном узле. Pipewire или Pulseaudio занимает этот TCP сокет при загрузке модуля module-native-protocol-tcp. По умолчанию это 127.0.0.1:4713, но Вы могли изменить его в настройках модуля. В таком случае измените здесь.
lo_aud_sock=127.0.0.1:4713

#Проброс локального pipewire module-native-protocol-tcp на этот сокет на удалённом узле. Это некий прокси-сокет, что будет создан на удалённом компьютере. Входящие на него соединения будут перенаправлены на локальный узел внутри SSH.
fw_aud_sock=127.0.0.1:64713

#Путь к файлу сокета мастер-соединения SSH. Благодаря нему разные экземпляры SSH клиента могут совместно использовать одно SSH соединение в несколько потоков. Если приложение ssh (клиент) неожиданно завершилось, файл сокета останется ввиде безполезного мусора. В его имя добавлен UNIX Timestamp чтобы избежать конфликтов. Он размещён в папке tmp, чтобы был удалён при перезагрузке.
ssh_sock_file=/tmp/x-combo-remote-sock-$(date +%s).ssh

#На одном узле можно одновременно запустить несколько дисплеев X, для удобства они имеют номера. Если Вы используете одну активную видеокарту и графический рабочий стол отображается на мониторах, подключённых к этой видеокарте, то скорее всего номер X дисплея будет :0 но в особенных конфигурациях (например многопользовательский компьютер, терминальный сервер, несколько активных видеокарт), номер может быть другим. Если не знаете его, в терминале выполните [ echo $DISPLAY ]
rm_x_display=:0

#Параметры запуска x11vnc в роли VNC сервера на удалённом узле. Чтобы узнать о них подробнее обратитесь к документации x11vnc.
declare -a x11vnc_params=(
-xkb #Принудительный фикс клавиатуры.
#-noxkb #Принудительное отключение фикса клавиатуры.
-repeat #Принудительно разблокировать автоповтор клавиатуры.
#-norepeat #Принудительно заблокировать автоповтор клавиатуры.
-rfbport 5900 #Слушать этот TCP порт.
-localhost #Слушать порт только на localhost.
-nowireframe #Не скрывать содержимое окон при перетсакивании.
-nopw #Без VNC-пароля
-timeout 10 #Остановить сервер если клиент не подключился за столько секунд.
-quiet #Без логов.
-display $rm_x_display #Номер целевого X дисплея.
)

#Диагностика выполняется после установки SSH мастер-соединения, она не позволяет продолжить при обнаружении проблем. Вы можете отключить диагностику для ускорения, но если некоторые функции не будут работать, Вы не узнаете, почему.
simple_diag_enabled=true

#Отладочные настройки. Если Вы решите изучать и править этот скрипт - Вы и сами найдёте, как они работают. А если просто используете - не обращайте на них внимания.
remote_host=$1
debug_enabled="false"



#Цвета
#- - - - - - - - - - - - - - - - - - - - - - - - -
RST='\033[0m'
CYAN='\e[38;5;51m'
RED='\e[38;5;160m'
GREEN='\e[38;5;34m'
BLUE='\e[38;5;33m'
GRAY='\e[38;5;242m'



logo() {
  echo '____  _________________  ___'
  echo '__  |/ /__  ____/___   |/  /'
  echo '__    / _  /     __  /|_/ / '
  echo '_    |  / /___   _  /  / /  '
  echo '/_/|_|  \____/   /_/  /_/   '
  echo "          x-combo-remote by ivanet"
  echo ""
}


debug_shell() {
exec bash --init-file <(
cat <<EOF
source "$0"
PS1='debug> '
EOF
) -i
}


ssh_create_master() {
ssh -M -S $ssh_sock_file -o NumberOfPasswordPrompts=3 -o ConnectTimeout=6 -fN $remote_host
if [[ $? != 0 ]]; then
	echo -e $RED"[-] SSH клиент завершился с ошибкой."$RST
	exit 1
fi
}


ssh_remote_exec(){
ssh -S $ssh_sock_file -q -o NumberOfPasswordPrompts=0 $remote_host "$@"
}


ssh_close_socket(){
ssh -S $ssh_sock_file -q -o NumberOfPasswordPrompts=0 -O exit $remote_host
rm -f $ssh_sock_file
}


ssh_check_master() {
result=$(ssh_remote_exec "ls /dev/null")
if [[ $result == '/dev/null' ]]; then
	echo pass
else
	echo fail
fi
}


ssh_add_tcpforwarding() {
ssh -S $ssh_sock_file -fnN -q -o NumberOfPasswordPrompts=0 $1 $remote_host
if [[ $? != 0 ]]; then
	echo -e $RED"[-] SSH клиент завершился с ошибкой."$RST
	exit 1
fi
}


start_vnc_server() {
ssh_remote_exec "screen -dmS x-combo-remote_vnc-server x11vnc ${x11vnc_params[@]}"
}

run_vnc() {
vnc_client_pid=$(pgrep -f x-combo-remote_vnc-client)
if [[ $vnc_client_pid != '' ]]; then
	echo -ne $BLUE"-> Стоп VNC\r"$RST
	pkill $vnc_client_pid
	export vnc_client_pid=''
else
	echo -ne $BLUE"-> Пуск VNC\r"$RST
	start_vnc_server
	screen -dmS x-combo-remote_vnc-client $vnc_client $fw_vnc_sock
	vnc_client_pid=$(pgrep -f x-combo-remote_vnc-client)
fi
}


close_script() {
if [[ $vnc_client_pid != '' ]]; then
	pkill $vnc_client_pid
	export vnc_client_pid=''
fi
if [[ $clipboard_monitor_pid != '' ]]; then
	pkill $clipboard_monitor_pid
	export clipboard_monitor_pid=''
fi
if [[ $audio_running == 1 ]]; then
	audio_stop
	export audio_running=0
fi
if [[ $microphone_running == 1 ]]; then
	microphone_stop
	export microphone_running=0
fi
ssh_close_socket
kill $print_state_pid &> /dev/null
print_state --once
echo ""
echo "Конец работы скрипта"
echo "- - - - - - - - - - - - - - - - -"
exit
}


clear_line() {
echo -ne "\r                                                       \r"
}

wrong_input() {
echo -ne "<неверный ввод>\r"
sleep 1
clear_line
}


clipboard_monitor() {
lo_check_need=1
rm_check_need=1
while true
do
	#Локальный
	if [[ $lo_check_need == 1 ]]; then
		lo_clip_now=$(xsel -o -b)
		if [[ $lo_clip_now != $lo_clip_last ]]; then
			echo -n "$lo_clip_now" | ssh -S $ssh_sock_file $remote_host "DISPLAY=$rm_x_display xsel -b -i"
			export lo_clip_last=$lo_clip_now
			export rm_clip_now=$lo_clip_now
			export rm_clip_last=$lo_clip_now
			export rm_check_need=0
		fi
	else
		export lo_check_need=1
	fi

	#Удалённый
	if [[ $rm_check_need == 1 ]]; then
		rm_clip_now=$(ssh -S $ssh_sock_file $remote_host "DISPLAY=$rm_x_display xsel -o -b")
		if [[ $rm_clip_now != $rm_clip_last ]]; then
			echo -n "$rm_clip_now" | xsel -b -i
			export rm_clip_last=$rm_clip_now
			export lo_clip_now=$rm_clip_now
			export lo_clip_last=$rm_clip_now
			export lo_check_need=0
		fi
	else
		export rm_check_need=1
	fi
	sleep 0.6
done
}

control_clipboard_monitor() {
if [[ $clipboard_monitor_pid != '' ]]; then
	echo -ne $BLUE"-> Стоп Буфер обмена\r"$RST
	kill $clipboard_monitor_pid &> /dev/null
	export clipboard_monitor_pid=''
else
	echo -ne $BLUE"-> Пуск Буфер обмена\r"$RST
	clipboard_monitor &
	export clipboard_monitor_pid=$!
fi
}


audio_control() {
if [[ $audio_running == 1 ]]; then
	echo -ne $BLUE"-> Стоп Аудио\r"$RST
	audio_stop
	export audio_running=0
else
	echo -ne $BLUE"-> Пуск Аудио\r"$RST
	audio_run
	export audio_running=1
fi
last_audio_control=$(date +%s)
}


audio_run(){
if [[ $(pactl list modules | grep module-native-protocol-tcp) == '' ]]; then
	pactl load-module module-native-protocol-tcp listen=127.0.0.1 &> /dev/null
fi

rm_normal_sink=$(ssh_remote_exec "pactl get-default-sink")
ssh_remote_exec "pactl load-module module-tunnel-sink server=$fw_aud_sock &> /dev/null"
ssh_remote_exec "pactl set-default-sink tunnel-sink.$fw_aud_sock &> /dev/null"
}


audio_stop() {
ssh_remote_exec "pactl set-default-sink $rm_normal_sink &> /dev/null"
ssh_remote_exec "pactl unload-module module-tunnel-sink &> /dev/null"
}


microphone_control() {
if [[ $microphone_running == 1 ]]; then
	echo -ne $BLUE"-> Стоп Микрофон\r"$RST
	microphone_stop
	export microphone_running=0
else
	echo -ne $BLUE"-> Пуск Микрофон\r"$RST
	microphone_run
	export microphone_running=1
fi
}


microphone_run(){
if [[ $(pactl list modules | grep module-native-protocol-tcp) == '' ]]; then
	pactl load-module module-native-protocol-tcp listen=127.0.0.1 &> /dev/null
fi

rm_normal_source=$(ssh_remote_exec "pactl get-default-source")
ssh_remote_exec "pactl load-module module-tunnel-source server=$fw_aud_sock &> /dev/null"
ssh_remote_exec "pactl set-default-source tunnel-source.$fw_aud_sock &> /dev/null"
}


microphone_stop() {
ssh_remote_exec "pactl set-default-source $rm_normal_source &> /dev/null"
ssh_remote_exec "pactl unload-module module-tunnel-source &> /dev/null"
}


simple_diag() {
if [[ $simple_diag_enabled != true ]];then
	return 0
fi

echo -ne $GRAY"Диагностика...\r"$RST

declare -a lo_commands=(
$vnc_client
ssh
rm
pkill
pgrep
grep
ss
screen
sleep
xsel
date
pactl
)

for cmd in "${lo_commands[@]}"
do
	type $cmd &> /dev/null
	if [[ $? != 0 ]]; then
		echo -e $RED"[-] Диагностика не пройдена"$RST
		echo -e "Команда"$CYAN $cmd $RST"недоступна на локальном узле."
		echo -e "Убедитесь что приложение установлено и окружение исправно."
		ssh_close_socket
		exit 1
	fi
done

declare -a rm_commands=(
x11vnc
screen
xsel
pactl
ss
grep
)

for cmd in "${rm_commands[@]}"
do
	result=$(ssh_remote_exec "type $cmd &> /dev/null")
	if [[ $? != 0 ]]; then
		echo -e $RED"[-] Диагностика не пройдена"$RST
		echo -e "Команда"$CYAN $cmd $RST"недоступна на удалённом узле."
		echo -e "Убедитесь что приложение установлено и окружение исправно."
		ssh_close_socket
		exit 1
	fi
done

declare -a lo_socks=(
$fw_vnc_sock
)

for sock in "${lo_socks[@]}"
do
	result=$(ss -tln | grep "$sock")
	if [[ $result != '' ]]; then
		echo -e $RED"[-] Диагностика не пройдена"$RST
		echo -e "Сокет"$CYAN $sock $RST"на удалённом узле занят другим процессом."
		echo -e $GRAY"Освободите сокет или замените его на другой в настройках скрипта."$RST
		echo -e $GRAY"Выполните на нём "$RST"sudo ss -lntup | grep \"$sock\""$GRAY" для подробностей."$RST
		ssh_close_socket
		exit 1
	fi
done

declare -a rm_socks=(
$rm_vnc_sock
$fw_aud_sock
)

for sock in "${rm_socks[@]}"
do
	result=$(ssh_remote_exec "ss -tln | grep $sock")
	if [[ $result != '' ]]; then
		echo -e $RED"[-] Диагностика не пройдена"$RST
		echo -e "Сокет"$CYAN $sock $RST"на локальном узле занят другим процессом."
		echo -e $GRAY"Освободите сокет или замените его на другой в настройках скрипта."$RST
		echo -e $GRAY"Выполните "$RST"sudo ss -lntup | grep \"$sock\""$GRAY" для подробностей."$RST
		ssh_close_socket
		exit 1
	fi
done

echo -e $GREEN"[+] Диагностика пройдена."$RST
}


setup_ssh_forwards() {
ssh_add_tcpforwarding "-L $fw_vnc_sock:$rm_vnc_sock"
ssh_add_tcpforwarding "-R $fw_aud_sock:$lo_aud_sock"
}

print_state() {
trap 'export print_state_stop=1' SIGTERM
while true
do
	echo -ne "\033[5A"
	vnc_client_pid=$(pgrep -f x-combo-remote_vnc-client)
	if [[ $vnc_client_pid != '' ]]; then
		echo -e $CYAN"    1"$RST" VNC           "$GREEN"[ON] "$RST
	else
		echo -e $CYAN"    1"$RST" VNC           "$GRAY"[OFF]"$RST
	fi
	if [[ $clipboard_monitor_pid != '' ]]; then
		echo -e $CYAN"    2"$RST" Буфер обмена  "$GREEN"[ON] "$RST
	else
		echo -e $CYAN"    2"$RST" Буфер обмена  "$GRAY"[OFF]"$RST
	fi
	if [[ $audio_running == 1 ]]; then
		echo -e $CYAN"    3"$RST" Звук          "$GREEN"[ON] "$RST
	else
		echo -e $CYAN"    3"$RST" Звук          "$GRAY"[OFF]"$RST
	fi
	if [[ $microphone_running == 1 ]]; then
		echo -e $CYAN"    4"$RST" Микрофон      "$GREEN"[ON] "$RST
	else
		echo -e $CYAN"    4"$RST" Микрофон      "$GRAY"[OFF]"$RST
	fi

	if [[ $1 == '--once' ]]; then
		break
	else
		echo ""
		sleep 1
		clear_line
	fi

	if [[ $print_state_stop == 1 ]]; then
		export print_state_stop=0
		break
	fi
done
}


check_hostname() {
if [[ $(echo $remote_host) == '' ]]; then
	echo -e $RED"[-] Не указан удалённый узел."$RST
	echo -e $GRAY"Например:"$RST" ./x-combo-remote.sh 192.168.0.2"
	echo -e $GRAY"Например:"$RST" ./x-combo-remote.sh root@server2.local"
	echo -e $GRAY"Например:"$RST" ./x-combo-remote.sh \"nastya.mirnaya@ivanet.pro -p 50022\""
	exit
fi
}


main_menu() {
echo ""
echo "Доступные функции:"
echo -e $CYAN"    1"$RST" VNC"
echo -e $CYAN"    2"$RST" Буфер обмена"
echo -e $CYAN"    3"$RST" Звук"
echo -e $CYAN"    4"$RST" Микрофон"
echo ""
while true
do
	print_state &
	print_state_pid=$!
	read -s -n1 input
	kill $print_state_pid &> /dev/null
	case $input in
		1) run_vnc ;;
		2) control_clipboard_monitor ;;
		3) audio_control ;;
		4) microphone_control ;;
		*) wrong_input & ;;
	esac
	export input=''
done
}


master_or_exit() {
if [[ $(ssh_check_master) == 'pass' ]]; then
	echo -e $GREEN"[+] SSH мастер-соединение установлено."$RST
else
	echo -e $RED"[-] SSH мастер-соединение не установлено."$RST
	ssh_close_socket
	exit 1
fi
}




#------------------------------------------#
if [[ $debug_enabled != 'true' ]]; then
	trap 'close_script' SIGINT
	check_hostname
	logo
	ssh_create_master
	master_or_exit
	simple_diag
	setup_ssh_forwards
	main_menu
	close_script
else
	echo "Режим ручной отладки"
	PS1='debug> '
fi
#------------------------------------------#