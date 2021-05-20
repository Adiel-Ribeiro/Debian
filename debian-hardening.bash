################# debian hardening #########################################################################
#!/bin/bash 
############################################################################################################
######################### umask ############################################################################
sudo bash -c "echo umask 077 >> /etc/profile"
######################### networking #######################################################################
sudo hostname master
sudo bash -c "echo master > /etc/hostname"
sudo bash -c "echo `/sbin/ifconfig | grep inet | awk {'print $2'} | awk 'NR==1'` `hostname`\
>> /etc/cloud/templates/hosts.debian.tmpl"
#############################################################################################################
##################### ssh ###################################################################################
sudo groupadd sshd
sudo usermod -a -G sshd admin
sudo mv /etc/ssh/sshd_config /etc/ssh/sshd_config.bkp
sudo curl https://raw.githubusercontent.com/Adiel-Ribeiro/Debian/master/sshd_config -o /etc/ssh/sshd_config
sudo chmod 400 /etc/ssh/sshd_config 
#############################################################################################################
##################### logging ###############################################################################
sudo chattr +a /var/log/auth.log
#############################################################################################################
sudo bash -c "echo net.ipv6.conf.all.disable_ipv6 = 1 >> /etc/sysctl.conf"
sudo bash -c "echo net.ipv6.conf.default.disable_ipv6 = 1  >> /etc/sysctl.conf"
sudo bash -c "echo net.ipv6.conf.lo.disable_ipv6 = 1  >> /etc/sysctl.conf"
##############################################################################################################
rm debian-hardening.bash
sudo reboot
