# mundise-pin
PIN MundosE Devops 2301



Se Plantea instalar una aplicacion con persistencia de datos en DDBB



### Creating the RDS PostgreSQL + ECR repository

# terraform create vpc + rds postgresql db + ecr repo
```
make rds-ecr-create
```

# terraform create ec2 bastion for ssh tunnel
$ make bastion-ssh-create

