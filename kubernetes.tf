provider "aws"                          {
 region                                 =         "us-east-1"
 shared_credentials_file                =         "/data/it/terraform/kubernetes/.cred"
 profile                                =         "default"
}

resource "aws_instance" "kubernetes-homolog"       {
 ami                                    =         "ami-07d02ee1eeb0c996c"
 instance_type                          =         "t3.medium"
 vpc_security_group_ids                 =         ["sg-0f6a35bdf5d37a70d"]
 subnet_id                              =         "subnet-0aaa911afb97cd735"
 associate_public_ip_address            =         "1"
# iam_instance_profile                   =        "ecsInstanceRole" 
# cpu_core_count                         =        "1" 
 cpu_threads_per_core                   =         "2" 
 instance_initiated_shutdown_behavior   =         "stop"
 disable_api_termination                =         "0"
 monitoring                             =         "0" 
 tenancy                                =         "default"

root_block_device                       { 
 volume_size                            =         "8"
 delete_on_termination                  =         "true" 
 encrypted                              =         "false" 
# kms_key_id                            = 
}

#ebs_block_device                        {
# device_name                            =         "/dev/sdf"
# volume_size                            =         "15"
# volume_type                            =         "gp2"
# delete_on_termination                  =         "true"
# encrypted                              =         "false"
#}

tags                                    =         {
 Name                                   =         "kubernetes-master"
} 

volume_tags                             = {
 Name                                   =         "kubernetes-master"
}

provisioner "file"                      {
 source                                 =         "/data/it/github/debian/debian-hardening.bash"
 destination                            =         "/tmp/debian-hardening.bash"
}

provisioner "remote-exec"               {
 inline                                 = [
 "chmod +x /tmp/debian-hardening.bash",
 "/tmp/debian-hardening.bash",
 ]
}

availability_zone                       =        "us-east-1a"

key_name                                =        "study" 

connection                              {
 type                                   =        "ssh"
 user                                   =        "admin"
 private_key                            =        "${file("/home/adiel/ansible/study.pem")}"
 host                                   =         self.public_ip
 port                                   =        "22"
}

}