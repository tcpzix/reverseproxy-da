###################################### Explanatin ###################################################################
#    about this script:                                                                                             #
#       - please run it on centos7-nolvm image                                                                      #
#    what it do:                                                                                                    #
#        - run yum update                                                                                           #
#        - install [nginx latest-stable] and [sshpass]                                                              #
#        - ask for Directadmin ssh info to export domains from not suspende users                                   #
#        - split exported domains in two list [domain whith ssl - domains without ssl]                              #
#        - copy ssl files for domains in [domains whit ssl] list                                                    #
#        - make a tar file from domians list and ssl file [exported_data.tar]                                       #
#        - move [exported_data.tar] from directadmin to current server and generate nginx config files              #      
#####################################################################################################################
#!/bin/bash
read -p "Enter Directadmin server ip: " da_ip
read -p "Enter Directadmin server ssh port: " da_ssh_port
read -p "Enter Directadmin server ssh username: " da_ssh_user
read -s -p "Enter Directadmin server ssh password: " da_ssh_pass
yum update -y
yum install nginx -y
yum install sshpass -y
mkdir ./temp-for-nginx
# connect to directadin and export domains #
sshpass -p $da_ssh_pass ssh -o StrictHostKeyChecking=no $da_ssh_user@$da_ip 'bash -s' <<"ENDSSH"
da_cache_file="/usr/local/directadmin/data/admin/show_all_users.cache"    # this file contain almost everything about each user 
temp_dir="/root/temp-for-nginx/"
user_data_dir="/usr/local/directadmin/data/users"
mkdir -p $temp_dir && mkdir $temp_dir/ssl_files/
cd $temp_dir
# regenerate da_cache_file # 
mv $da_cache_file $da_cache_file.backup
echo "action=cache&value=showallusers" >> /usr/local/directadmin/data/task.queue
/usr/local/directadmin/dataskq d > /dev/null 2>&1
while [ ! -f $da_cache_file ]; do echo "# waiting for re-generating DA cache file #"; sleep 2; done
cp $da_cache_file $temp_dir
# export all domains for NOT-SUSPENDED users and check for ssl files #
while read -r line;
do 
    username=$(echo $line | awk -F "/" '{print $1}' - | awk -F "=" '{print $1}' -)
    suspend=$(echo $line | awk -F "/" '{print $4}' - | awk -F "suspended=" '{print $2}' | awk -F "&" '{print $1}')
    domains=$(echo $line | awk -F "/" '{print $3}' -  | awk -F "list=" '{print $2}' - | awk -F "&" '{print $1}' - | sed 's/<br>/ /g')
    if [ "$suspend" = "No" ]; then        
        echo $username:$domains >> user_domain.list
        for domain in $domains; do 
            ssl_cert="$user_data_dir/$username/domains/$domain.cert"
            ssl_ca="$user_data_dir/$username/domains/$domain.cacert"
            ssl_key="$user_data_dir/$username/domains/$domain.key"
            if [ ! -f $ssl_cert ] || [ ! -f $ssl_key ] || [ ! -f $ssl_ca ];
                then
                    echo $domain >> domains_without_ssl.list
                else
                    echo $domain >> domains_with_ssl.list
                    cp $ssl_key ssl_files/
                    cat $ssl_cert $ssl_ca > ssl_files/$domain.cert 
            fi
       done
    fi
done < show_all_users.cache
tar -cf exported_data.tar * > /dev/null 2>&1
ENDSSH
# move [exported_data.tar] to current server and delete it from directadmin #
sshpass -p $da_ssh_pass scp -o StrictHostKeyChecking=no  $da_ssh_user@$da_ip:/root/temp-for-nginx/exported_data.tar temp-for-nginx/
sshpass -p $da_ssh_pass ssh -o StrictHostKeyChecking=no  $da_ssh_user@$da_ip 'rm -rf /root/temp-for-nginx'
tar -xf temp-for-nginx/exported_data.tar -C temp-for-nginx/
# Generate nginx config #
\cp -rf temp-for-nginx/ssl_files /etc/nginx/conf.d/
cat > /etc/nginx/nginx.conf <<EOF
worker_processes  auto;
events {
	worker_connections 1024;
	accept_mutex off;
}
http {
    ssl_session_cache   shared:SSL:10m;
    ssl_session_timeout 10m;
	proxy_buffering     on;
	proxy_http_version	1.1;
	proxy_socket_keepalive on;
	proxy_set_header	Host \$host;
	proxy_set_header 	X-Real-IP \$remote_addr;
	proxy_set_header 	X-Forwarded-For \$proxy_add_x_forwarded_for;
	
	upstream backend {
		server 		$da_ip;
	}
	
	# this is for undefined domains
	server {						
		listen		80	default_server;
		return 		444; 			# by returning 444 nginx close the connection and return nothing
	}
	include conf.d/*.conf;          # import vhost config files
}
EOF
# generate vhost config file for domains #
while read -r domain;do
cat > /etc/nginx/conf.d/$domain.conf << EOF
    server {
        listen		80;
        server_name	.$domain;
        location 	/ {
            proxy_pass	http://backend;
        }
    }
    server {
        listen 				443 ssl;
        ssl_certificate_key conf.d/ssl_files/$domain.key;
        ssl_certificate     conf.d/ssl_files/$domain.cert;
        ssl_protocols       TLSv1 TLSv1.1 TLSv1.2;
        ssl_ciphers         HIGH:!aNULL:!MD5;
        location / {
            proxy_pass		http://backend;
        }
    }
EOF
done < temp-for-nginx/domains_with_ssl.list
while read -r domain;do
cat > /etc/nginx/conf.d/$domain.conf << EOF
server {
	listen		80;
	server_name	.$domain;
	location 	/ {
		proxy_pass	http://backend;
	}
}
EOF
done < temp-for-nginx/domains_without_ssl.list
nginx -t
systemctl restart nginx
systemctl enable nginx > /dev/null 2>&1
systemctl status nginx 
netstat -tulpn | grep nginx
