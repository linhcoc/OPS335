#!/bin/bash

### ALL INPUT BEFORE CHECKING #### -------------------
domain="towns.ontario.ops"
vms_name=(toronto ottawa kingston coburg milton)   ###-- Put the name in order --  Master Slave Other Machines
vms_ip=(172.17.15.2 172.17.15.3 172.17.15.5 172.17.15.6 172.17.15.8)	
		
################ INPUT from USER ########################

clear
if zenity --forms --title="INFORMATION" \
	--text="INPUT USER INFORMATION" \
	--add-entry="Your Seneca Username" \
	--add-entry="Your Full Name" \
	--add-password="Enter your normal password" > var
then
	username=$(cut -d\| -f1 var)
	fullname=$(cut -d\| -f2 var)
	password=$(cut -d\| -f3 var)
	if [ -z $username ] || [ -z "$fullname" ] || [ -z $password ]
	then
		echo
		echo
		echo -e "\e[31mValue is empty. Run the script and input again\e[m"
		exit 2
		rm -rf var
		echo
		echo
	fi
else
echo -e "\e[31mJob cancelled\e[m"
exit 3
rm -rf var
fi	
################ DONE - INPUT from USER ########################


################# GRAB DIGITS FROM IP #########################
IP=$(cat /var/named/mydb-for-* | grep ^vm1 | head -1 | awk '{print $4}')
digit=$(cat /var/named/mydb-for-* | grep ^vm2 | head -1 | awk '{print $4}' | cut -d. -f3)
		

################### Create Hash Table ######################
		
for (( i=0; i<${#vms_name[@]};i++ ))
do
	declare -A dict
	dict+=(["${vms_name[$i]}"]="${vms_ip[$i]}")
done


############### CHECKING ALL THE REQUIREMENT BEFORE RUNNING THE SCRIPT ############################
function require {

	################## CHECKING FUNCTION #################

	function check() {
		if eval $1
		then
			echo -e "\e[32mOK. GOOD \e[0m"
		else
			echo
	     		echo
	     		echo -e "\e[0;31mWARNING\e[m"
	     		echo
	     		echo
	     		echo $2
	     		echo
	     		exit 1
		fi	
	}
	################# DONE - CHECKING FUNTION ###################	



	########## Run script by Root ##################

		if [ `id -u` -ne 0 ]
		then
			echo "Must run this script by root" >&2
			exit 2
		fi

	########## Backing up before runnning the script ############

		echo -e "\e[1;31m--------WARNING----------"
		echo -e "\e[1mBackup your virtual machine to run this script \e[0m"
		echo
		if zenity --question --title="BACKUP VIRTUAL MACHINES" --text="DO YOU WANT TO MAKE A BACKUP"
		then
			echo -e "\e[1;35mBacking up in process. Wait... \e[0m" >&2
			for shut in $(virsh list --name)  ## --- shutdown vms to backup --- ###
			do
				virsh shutdown $shut
				while virsh list | grep -iqs $shut
				do
					echo $shut is being shutdown to backup. Wait
	                sleep 3
				done
			done
			yum install pv -y  > /dev/null 2>&1
			
			for bk in $(ls /var/lib/libvirt/images/ | grep -v vm* | grep \.qcow2$)
			do
				echo "Backing up $bk"
				mkdir -p /backup/full 2> /dev/null
				pv /var/lib/libvirt/images/$bk | gzip | pv  > /backup/full/$bk.backup.gz
			done
		fi
		
	######## CHECKING VMS STATUS  ################################ 
		echo -e "\e[1;35mChecking VMs status\e[m"
		for vm in ${!dict[@]}
		do 
			if ! virsh list | grep -iqs $vm
			then
				virsh start $vm > /dev/null 2>&1
				while ! eval "ping ${dict[$vm]} -c 5 > /dev/null" 
				do
					echo -e "\e[1;34mMachine $vm is turning on \e[0m" >&2
					sleep 3
				done
			fi
		done
	
	################# SSH and Pinging and Update Check #########################

	echo -e "\e[1;35mRestarting Named\e[m"
	systemctl restart named
	echo -e "\e[32mRestarted Done \e[m"

	check "ping -c 3 google.ca > /dev/null" "Host machine can not ping GOOGLE.CA, check INTERNET connection then run the script again"

		
	for ssh_vm in ${!dict[@]} ## -- Checking VMS -- ## KEY
	do
	check "ssh -o ConnectTimeout=5 -oStrictHostKeyChecking=no ${dict[$ssh_vm]} ls > /dev/null" "Can not SSH to $ssh_vm, check and run the script again "
	check "ssh ${dict[$ssh_vm]} ping -c 3 google.ca > /dev/null" "Can not ping GOOGLE.CA from $ssh_vm, check internet connection then run the script again"
	check "ssh ${dict[$ssh_vm]} yum update -y" "Can not YUM UPDATE from $ssh_vm"
	done



	########### CLONING VMS FUNTION START ####################

	function clone-machine {
		echo -e "\e[1;35mChecking clone machine\e[m"
		count=0
		for vm in ${vms_name[@]}
		do 
			if ! virsh list --all | grep -iqs $vm
			then
				echo 
				echo
				echo -e "\e[1;31m$vm need to be created\e[m"
				echo
				echo
				count=1
			fi
		done
		check "yum install virt-clone" "Can not install packages. Check INTERNET connection"
		

		if [ $count -gt 0 ]
		then
			echo
			echo -e "\e[1;32m###### CLONING MACHINES IS PROCESSING... #######\e[m"
			echo
			check "virsh start cloyne 2> /dev/null" "Can not start cloyne machine"

			############# Set up clone-machine configuration before cloning
			check "ssh -o ConnectTimeout=5 172.17.15.100 ls > /dev/null" "Can not SSH to Cloyne, check and run the script again"
			intcloyne=$(ssh 172.17.15.100 '( ip ad | grep -B 2 172.17.15 | head -1 | cut -d" " -f2 | cut -d: -f1 )' )  #### grab interface infor (some one has ens3)
			maccloyne=$(ssh 172.17.15.100 grep ".*HWADDR.*" /etc/sysconfig/network-scripts/ifcfg-$intcloyne) #### grab mac address
			
			############# INTERFACES COLLECTING
			check "ssh 172.17.15.100 grep -v -e '.*DNS.*' -e 'DOMAIN.*' -e 'DEVICE.*' /etc/sysconfig/network-scripts/ifcfg-$intcloyne > ipconf.txt" "File or directory not exist"
			echo "DNS1="172.17.15.2"" >> ipconf.txt
			echo "DNS2="172.17.15.3"" >> ipconf.txt
			echo "PEERDNS=no" >> ipconf.txt
			echo "DOMAIN=towns.ontario.ops" >> ipconf.txt
			echo "DEVICE=$intcloyne" >> ipconf.txt
			sed -i 's/'${maccloyne}'/#'${maccloyne}'/g' ipconf.txt 2> /dev/null  #comment mac address in ipconf.txt file
			check "scp ipconf.txt 172.17.15.100:/etc/sysconfig/network-scripts/ifcfg-$intcloyne > /dev/null" "Can not copy ipconf to Cloyne"
			rm -rf ipconf.txt > /dev/null
			sleep 2
			echo
			echo -e "\e[32mCloyne machine info has been collected\e[m"
			ssh 172.17.15.100 init 6 > /dev/null 2>&1

			while ! eval "ping 172.17.15.100 -c 5 > /dev/null" 
			do
				echo "Clonning machine is processing"
				sleep 3
			done
			sleep 3
			virsh suspend cloyne			
		
			############# CLONING PROGRESS BEGIN #####

			for clonevm in ${!dict[@]} # Key (name vm)
			do 
				if ! virsh list --all | grep -iqs $clonevm
				then
					echo -e "\e[1;35mCloning $clonevm \e[m"
					virt-clone --auto-clone -o cloyne --name $clonevm

				#-----Turn on cloned vm without turning on cloyne machine
				virsh start $clonevm
				while ! eval "ping 172.17.15.100 -c 5 > /dev/null" 
				do
					echo "Clonning machine is starting"
					sleep 3
				done
				#------ get new mac address
				newmac=$(virsh dumpxml $clonevm | grep "mac address" | cut -d\' -f2)
				#-----Replace mac and ip, hostname
				ssh 172.17.15.100 "sed -i 's/.*HW.*/HWADDR\='${newmac}'/g' /etc/sysconfig/network-scripts/ifcfg-$intcloyne" ## change mac
				ssh 172.17.15.100 "echo $clonevm.towns.ontario.ops > /etc/hostname "  #change host name
				ssh 172.17.15.100 "sed -i 's/'172.17.15.100'/'${dict[$clonevm]}'/' /etc/sysconfig/network-scripts/ifcfg-$intcloyne" #change ip
				echo
				echo -e "\e[32mCloning Done $clonevm\e[m"
				ssh 172.17.15.100 init 6 > /dev/null 2>&1
				fi
			done

				echo -e "\e[35mRESET CLOYNE MACHINE TO DEFAULT\e[m"
				#------------------# reset cloyne machine
				oldmac=$(virsh dumpxml cloyne | grep "mac address" | cut -d\' -f2)
				virsh resume cloyne > /dev/null 2>&1
				while ! eval "ping 172.17.15.100 -c 5 > /dev/null" 
				do
					echo "Cloyne machine is starting"
					sleep 3
				done
				sleep 5
				ssh 172.17.15.100 "sed -i 's/.*HW.*/HWADDR\='${oldmac}'/g' /etc/sysconfig/network-scripts/ifcfg-$intcloyne"
				ssh 172.17.15.100 init 6 > /dev/null 2>&1
		fi
	}		
	clone-machine

	################# DONE - CLONING FUNCTION ###################




	
	### 5.Checking jobs done from Assignment 1 -------------------------

	#check "ssh ${vms_ip[0]} host ${vms_name[0]}.$domain > /dev/null 2>&1" "Name service in ${vms_name[0]} is not working"
	
}
require

### Start CONFIGURATION ###

virsh start toronto > /dev/null 2>&1
echo -e "\e[35mTurn on AutoStart Toronto\e[m"
virsh autostart toronto

## KINGSTON MACHINE ###

# Create user
echo -e "\e[1;35mCreate regular user\e[m"
ssh 172.17.15.5 useradd -m $username 2> /dev/null
ssh 172.17.15.5 '( echo '$username:$password' | chpasswd )'
echo -e "\e[32mUser Created \e[m"

# Install packages
echo -e "\e[1;35mInstall packages\e[m"
check "ssh 172.17.15.5 yum install -y mailx postfix" "Can not install mailx and postfix"
echo -e "\e[32mDone Installation \e[m"
ssh 172.17.15.5 setenforce permissive
check "ssh 172.17.15.5 systemctl start postfix" "Can not start services on KINGSTON"
check "ssh 172.17.15.5 systemctl enable postfix" "Can not enable services on KINGSTON"

# /Etc/main.cf file
cat > main.cf << EOF
queue_directory = /var/spool/postfix
command_directory = /usr/sbin
daemon_directory = /usr/libexec/postfix
data_directory = /var/lib/postfix
mail_owner = postfix
mydomain = towns.ontario.ops
myorigin = \$mydomain
inet_interfaces = all
inet_protocols = all
mydestination =  \$myhostname
unknown_local_recipient_reject_code = 550
relayhost = coburg.towns.ontario.ops
alias_maps = hash:/etc/aliases
alias_database = hash:/etc/aliases
debug_peer_level = 2
debugger_command =
	 PATH=/bin:/usr/bin:/usr/local/bin:/usr/X11R6/bin
	 ddd \$daemon_directory/\$process_name \$process_id & sleep 5
sendmail_path = /usr/sbin/sendmail.postfix
newaliases_path = /usr/bin/newaliases.postfix
mailq_path = /usr/bin/mailq.postfix
setgid_group = postdrop
html_directory = no
manpage_directory = /usr/share/man
sample_directory = /usr/share/doc/postfix-2.10.1/samples
readme_directory = /usr/share/doc/postfix-2.10.1/README_FILES
 
EOF

check "scp main.cf 172.17.15.5:/etc/postfix/main.cf" "Can not copy main.cf to kingston "
rm -rf main.cf > /dev/null
sleep 2

# Iptables
ssh 172.17.15.5 iptables -C INPUT -p tcp --dport 25 -j ACCEPT 2> /dev/null || ssh 172.17.15.5 iptables -I INPUT -p tcp --dport 25 -j ACCEPT
ssh 172.17.15.5 iptables -C INPUT -p udp --dport 25 -j ACCEPT 2> /dev/null || ssh 172.17.15.5 iptables -I INPUT -p udp --dport 25 -j ACCEPT
ssh 172.17.15.5 iptables-save > /etc/sysconfig/iptables
ssh 172.17.15.5 service iptables save
ssh 172.17.15.5 systemctl restart postfix
## --------KINGSTON DONE------------ ####

######################### COBURG MACHINE


# Create user
echo -e "\e[1;35mCreate regular user\e[m"
ssh 172.17.15.6 useradd -m $username 2> /dev/null
ssh 172.17.15.6 '( echo '$username:$password' | chpasswd )'
echo -e "\e[32mUser Created \e[m"

# Install packages
echo -e "\e[1;35mInstall packages\e[m"
check "ssh 172.17.15.6 yum install -y mailx postfix dovecot" "Can not install mailx and postfix and dovecot"
echo -e "\e[32mDone Installation \e[m"
ssh 172.17.15.6 setenforce permissive
check "ssh 172.17.15.6 systemctl start postfix" "Can not start services on COBURG"
check "ssh 172.17.15.6 systemctl start dovecot" "Can not start services on COBURG"
check "ssh 172.17.15.6 systemctl enable postfix" "Can not enable services on COBURG"
check "ssh 172.17.15.6 systemctl enable dovecot" "Can not enable services on COBURG"
# /Etc/postfix/main.cf
cat > main.cf << EOF
queue_directory = /var/spool/postfix
command_directory = /usr/sbin
daemon_directory = /usr/libexec/postfix
data_directory = /var/lib/postfix
mail_owner = postfix
mydomain = towns.ontario.ops
myorigin = \$mydomain
inet_interfaces = all
inet_protocols = all
mydestination = \$mydomain,\$myhostname, localhost.\$mydomain, localhost
unknown_local_recipient_reject_code = 550
mynetworks = 172.17.15.0/24, 127.0.0.0/8
alias_maps = hash:/etc/aliases
alias_database = hash:/etc/aliases
home_mailbox = mailboxes/
debug_peer_level = 2
debugger_command =
	 PATH=/bin:/usr/bin:/usr/local/bin:/usr/X11R6/bin
	 ddd \$daemon_directory/\$process_name \$process_id & sleep 5
sendmail_path = /usr/sbin/sendmail.postfix
newaliases_path = /usr/bin/newaliases.postfix
mailq_path = /usr/bin/mailq.postfix
setgid_group = postdrop
html_directory = no
manpage_directory = /usr/share/man
sample_directory = /usr/share/doc/postfix-2.10.1/samples
readme_directory = /usr/share/doc/postfix-2.10.1/README_FILES

EOF

check "scp main.cf 172.17.15.6:/etc/postfix/main.cf" "Can not copy main.cf to coburg "
rm -rf main.cf > /dev/null
sleep 2

# 10-mail.conf
cat > 10-mail.conf << EOF
mail_location = maildir:~/mailboxes:LAYOUT=fs
namespace inbox {
  inbox = yes
}
first_valid_uid = 1000
mbox_write_locks = fcntl

EOF
check "scp 10-mail.conf 172.17.15.6:/etc/dovecot/conf.d/10-mail.conf" "Can not copy 10-mail.conf to coburg "
rm -rf 10-mail.conf > /dev/null
sleep 2

# dovecot.conf
cat > dovecot.conf << EOF
protocols = imap
dict {
  #quota = mysql:/etc/dovecot/dovecot-dict-sql.conf.ext
  #expire = sqlite:/etc/dovecot/dovecot-dict-sql.conf.ext
}
!include conf.d/*.conf
!include_try local.conf
postmaster_address = towns.ontario.ops

EOF
check "scp dovecot.conf 172.17.15.6:/etc/dovecot/dovecot.conf" "Can not copy dovecot.conf to coburg "
rm -rf dovecot.conf > /dev/null
sleep 2

# 10-auth.conf
cat > 10-auth.conf << EOF
disable_plaintext_auth = no
auth_mechanisms = plain
!include auth-system.conf.ext

EOF
check "scp 10-auth.conf  172.17.15.6:/etc/dovecot/conf.d/10-auth.conf" "Can not copy 10-auth.conf  to coburg "
rm -rf 10-auth.conf  > /dev/null
sleep 2

# 10-ssl.conf
cat > 10-ssl.conf << EOF
ssl = yes
ssl_cert = </etc/pki/dovecot/certs/dovecot.pem
ssl_key = </etc/pki/dovecot/private/dovecot.pem

EOF
check "scp 10-ssl.conf 172.17.15.6:/etc/dovecot/conf.d/10-ssl.conf" "Can not copy 10-ssl.conf to coburg "
rm -rf 10-ssl.conf > /dev/null
sleep 2

# Aliases

ssh 172.17.15.6 "sed -i 's/^#root.*/root = '$username'/' /etc/aliases "


# Iptables
echo -e "\e[1;35mAdding iptables rules\e[m"
ssh 172.17.15.6 iptables -C INPUT -p tcp --dport 143 -s 172.17.15.0/24 -j ACCEPT 2> /dev/null || ssh 172.17.15.6 iptables -I INPUT -p tcp --dport 143 -s 172.17.15.0/24 -j ACCEPT
ssh 172.17.15.6 iptables -C INPUT -p tcp --dport 25 -j ACCEPT 2> /dev/null || ssh 172.17.15.6 iptables -I INPUT -p tcp --dport 25 -j ACCEPT
ssh 172.17.15.6 iptables -C INPUT -p udp --dport 25 -j ACCEPT 2> /dev/null || ssh 172.17.15.6 iptables -I INPUT -p udp --dport 25 -j ACCEPT
ssh 172.17.15.6 iptables-save > /etc/sysconfig/iptables
ssh 172.17.15.6 service iptables save
ssh 172.17.15.6 systemctl restart postfix
ssh 172.17.15.6 systemctl restart dovecot
## --------COBURG DONE------------ ####


## MILTON MACHINE
# Install packages
echo -e "\e[1;35mInstall packages on MILTON\e[m"
check "ssh 172.17.15.8 yum install -y samba*" "Can not install samba"
echo -e "\e[32mDone Installation \e[m"
check "ssh 172.17.15.8 systemctl start smb" "Can not start services on MILTON"
check "ssh 172.17.15.8 systemctl enable smb" "Can not enable services on MILTON"

# Create regular user
echo -e "\e[1;35mCreate regular user\e[m"
ssh 172.17.15.8 useradd -m $username 2> /dev/null
ssh 172.17.15.8 '( echo '$username:$password' | chpasswd )'

# Create SAMBA users,folders,groups,add user to group, give permissons
miltonusers="$username-1 $username-2 $username-admin"
for users in $miltonusers
do
	ssh 172.17.15.8 useradd -m $users 2> /dev/null
	ssh 172.17.15.8 '( echo '$users:$password' | chpasswd )'
cat << EOF | ssh 172.17.15.8 smbpasswd -s -a $users
$password
$password
EOF

	ssh 172.17.15.8 mkdir -p /documents/private/$users 2> /dev/null
	ssh 172.17.15.8 groupadd group$users 2>/dev/null	
	ssh 172.17.15.8 chown -R root:group$users /documents/private/$users 2> /dev/null
	ssh 172.17.15.8 chmod -R 775 /documents/private/$users 2> /dev/null
done

for b in $miltonusers
do
	ssh 172.17.15.8 gpasswd -M $b,$username-admin group$b 2> /dev/null
done

ssh 172.17.15.8 mkdir -p /documents/shared/readonly 2> /dev/null
ssh 172.17.15.8 chmod -R 775 /documents/shared/readonly 2> /dev/null
ssh 172.17.15.8 chown -R root:group$username-admin /documents/shared/readonly 2> /dev/null

ssh 172.17.15.8 mkdir -p /documents/shared/readwrite 2> /dev/null
ssh 172.17.15.8 chmod -R 777 /documents/shared/readwrite 2> /dev/null
echo -e "\e[32mUsers and Folders Created \e[m"

# SMB.CONF

cat > smb.conf << EOF

[global]
workgroup = WORKGROUP 
server string = $fullname-Assignment2
encrypt passwords = yes
smb passwd file = /etc/samba/smbpasswd
hosts allow = 172.17.15. 127.0.0.1
  
[$username-1]
comment = Assignment2
path = /documents/private/$username-1
public = no
writable = yes
printable = no
create mask = 0765
valid users = $username-1 $username-admin

[$username-2]
comment = Assignment2
path = /documents/private/$username-2
public = no
writable = yes
printable = no
create mask = 0765
valid users = $username-2 $username-admin

[$username-admin]
comment = Assignment2
path = /documents/private/$username-admin
public = no
writable = yes
printable = no
create mask = 0765
valid users = $username-admin

[readonly]
comment = Assignment2
path = /documents/shared/readonly
public = no
writable = yes
read list = $username-1 $username-2
write list = $username-admin
printable = no


[readwrite]
comment = Assignment2
path = /documents/shared/readwrite
public = no
writable = yes
printable = no
create mask = 0765
valid users = $username-1 $username-2 $username-admin 

EOF
check "scp smb.conf 172.17.15.8:/etc/samba/smb.conf " "Error when trying to copy SMB.CONF"
rm -rf smb.conf

# Selinux allows SMB
ssh 172.17.15.8 setsebool -P samba_enable_home_dirs on
ssh 172.17.15.8 setsebool -P samba_export_all_ro on
ssh 172.17.15.8 setsebool -P samba_export_all_rw on
# Config iptables
echo "Adding Firewall Rules"
ssh 172.17.15.8 iptables -C INPUT -p tcp --dport 445 -s 172.17.15.0/24 -j ACCEPT 2> /dev/null || ssh 172.17.15.8 iptables -I INPUT -p tcp --dport 445 -s 172.17.15.0/24 -j ACCEPT
ssh 172.17.15.8 iptables -C INPUT -p tcp --dport 139 -s 172.17.15.0/24 -j ACCEPT 2> /dev/null || ssh 172.17.15.8 iptables -I INPUT -p tcp --dport 139 -s 172.17.15.0/24 -j ACCEPT
ssh 172.17.15.8 iptables-save > /etc/sysconfig/iptables
ssh 172.17.15.8 service iptables save
ssh 172.17.15.8 systemctl restart smb

## --------MILTON DONE------------ ####
## TORONTO MACHINE
# MX Record
ssh 172.17.15.2 "sed -i 's/.*MX.*/towns.ontario.ops. IN MX 10 coburg.towns.ontario.ops.\ntowns.ontario.ops. IN MX 20 kingston.towns.ontario.ops./' /var/named/mydb-for-towns.ontario.ops "
#ssh 172.17.15.2 "sed -i "/^COMMIT/i towns.ontario.ops. IN MX 10 coburg.towns.ontario.ops.\ntowns.ontario.ops. IN MX 20 kingston.towns.ontario.ops." /var/named/mydb-for-towns.ontario.ops"
ssh 172.17.15.2 "systemctl restart named"

## Config Postfix permission for Toronto

ssh 172.17.15.2 "restorecon /etc/resolv.conf"
ssh 172.17.15.2 "restorecon -v -R /var/spool/postfix/"



#### TORONTO DONE --------------------

## CRONTAB
for crontab_vm in ${!dict[@]} ## -- Checking VMS -- ## KEY
do
mkdir -p /backup/incremental/cloning-source/$crontab_vm
crontab -l | { cat; echo "0 * * * * rsync -avz ${dict[$crontab_vm]}:/etc /backup/incremental/cloning-source/$crontab_vm"; } | crontab -
rsync -avz ${dict[$crontab_vm]}:/etc /backup/incremental/cloning-source/$crontab_vm 
done


echo
echo
echo -e "\e[1;32m-------------------LAB COMPLETED--------------\e[m"
echo
echo
echo 
cat > /root/Assignment2-information.txt << EOF
---------------INFORMATION YOU WILL NEED--------------------

# Thunderbird configuration on Kingston and Coburg Machines

+ Mail account: $username@towns.ontario.ops 
+ Mail Password: $password
+ Incoming IMAP Server: coburg.towns.ontario.ops    | Port: 143   | SSL: None | Normal Password 
+ Outgoing SMTP Server: kingston.towns.ontario.ops  | Port: 25    | SSL: None | No authentication 

#Samba Configuration on MILTON machine

+ Users for Samba: $username-1 $username-2 $username-admin
+ Password to login: $password
+ Path: 172.17.15.8

## All the above information will be stored in  /root/Assignment2-information.txt ##
------------------------------------------------------------
EOF
cat /root/Assignment2-information.txt
