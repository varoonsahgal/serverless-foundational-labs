 terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.16"
    }
  }
  required_version = ">= 1.2.0"
}

provider "aws" {
  region     = "us-west-2"
  access_key = "*****"
  secret_key = "*****"
}

/* ------- S3 Bucket ------ */
resource "aws_s3_bucket" "arev-tf-cp2-bucket-create" {
  bucket = "arev-tf-cp2-bucket"
}

resource "aws_s3_bucket_versioning" "arev-tf-cp2-bucket-verison" {
  bucket = aws_s3_bucket.arev-tf-cp2-bucket-create.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_object" "arev-tf-cp2-bucket-add" {
  for_each = fileset("./jsondata/", "**")
  bucket   = aws_s3_bucket.arev-tf-cp2-bucket-create.id
  key      = each.key
  source   = "./jsondata/${each.value}"
  etag     = filemd5("./jsondata/${each.value}")
}


/* ------- AWS Lambda ------ */
# data "aws_iam_role" "arev-tf-cp2-lambda-role" {
#   name = "room3-capstone2-gettodos-lambda-role"
# }

# data "archive_file" "arev-lambda-zip" {
#   type        = "zip"
#   source_file = "./resources/lambda.py"
#   output_path = "./resources/lambda_function.zip"
# }

# resource "aws_lambda_function" "arev-tf-cp2-lambda-create" {
#   function_name    = "arev-tf-cp2-lambda"
#   filename         = data.archive_file.arev-lambda-zip.output_path
#   source_code_hash = data.archive_file.arev-lambda-zip.output_base64sha256
#   role             = data.aws_iam_role.arev-tf-cp2-lambda-role.arn
#   handler          = "arev-tf-cp2-lambda.lambda_handler"
#   runtime          = "python3.9"
# }


# /* ------- API Gateway ------ */
# resource "aws_api_gateway_rest_api" "arev-tf-cp2-api-create" {

# }


/* ------- ECR Repo ------ */
resource "aws_ecr_repository" "arev-tf-cp2-ecr-repo" {
  name = "arev-tf-cp2-ecr-repo"
}



/* ------- CodeBuild Project ------ */
resource "aws_iam_role" "codebuild-ecr-role" {
  name               = "arev-tf-cp2-cb-role"
  assume_role_policy = data.aws_iam_policy_document.assume-codebuild-policy.json
}

data "aws_iam_policy_document" "assume-codebuild-policy" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["codebuild.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "codebuild-policy" {
  role = aws_iam_role.codebuild-ecr-role.id

  policy = <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Resource": [
        "*"
      ],
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ]
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3:*"
      ],
      "Resource": [
        "${aws_s3_bucket.codepipeline_bucket.arn}",
        "${aws_s3_bucket.codepipeline_bucket.arn}/*"
      ]
    },
    {
      "Effect": "Allow",
      "Action": [
        "ecs:UpdateService"
      ],
      "Resource": [
        "*"
      ]
    }
  ]
}
POLICY
}

resource "aws_iam_role_policy_attachment" "codebuild-ecr-policy" {
  role       = aws_iam_role.codebuild-ecr-role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser"
}


resource "aws_codebuild_project" "arev-tf-cp2-cb-create" {
  name         = "arev-tf-cp2-codebuild"
  description  = "arev-tf-codebuild-project"
  service_role = aws_iam_role.codebuild-ecr-role.arn

  artifacts {
    type = "NO_ARTIFACTS"
  }

  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = "aws/codebuild/standard:3.0"
    type                        = "LINUX_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"

    privileged_mode = true

    environment_variable {
      name  = "AWS_ACCOUNT_ID"
      value = "962804699607"
    }
    environment_variable {
      name  = "AWS_DEFAULT_REGION"
      value = "us-west-2"
    }
    environment_variable {
      name  = "IMAGE_REPO_NAME"
      value = aws_ecr_repository.arev-tf-cp2-ecr-repo.id
    }
    environment_variable {
      name  = "IMAGE_TAG"
      value = "latest"
    }
    environment_variable {
      name  = "CLUSTER_NAME"
      value = aws_ecs_cluster.arev-tf-cp2-cluster.id
    }
    environment_variable {
      name  = "SERVICE_NAME"
      value = aws_ecs_service.arev-tf-cp2_service.id
    }
  }

  source {
    type            = "GITHUB"
    location        = "https://github.com/stevenng/room3capstone2.git"
    git_clone_depth = 1
  }
}



/* ------- CodePipeline ------ */
resource "aws_codepipeline" "arev-tf-cp2-cp-create" {
  name     = "arev-tf-cp2-codepipeline"
  role_arn = aws_iam_role.codepipeline-service-role.arn

  artifact_store {
    location = aws_s3_bucket.codepipeline_bucket.bucket
    type     = "S3"
  }

  stage {
    name = "Source"

    action {
      name             = "Source"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeStarSourceConnection"
      version          = "1"
      run_order        = 1
      output_artifacts = ["source_output"]

      configuration = {
        "ConnectionArn"    = aws_codestarconnections_connection.arev-tf-cp2-connection.arn
        "FullRepositoryId" = "tewqs-a/room3capstone2"
        "BranchName"       = "master"
      }
    }
  }

  stage {
    name = "Build"

    action {
      name            = "Build"
      category        = "Build"
      owner           = "AWS"
      provider        = "CodeBuild"
      input_artifacts = ["source_output"]
      version         = "1"
  
      configuration = {
        "ProjectName" = aws_codebuild_project.arev-tf-cp2-cb-create.id
      }
    }
  }
}

resource "aws_s3_bucket" "codepipeline_bucket" {
  bucket = "arev-cp-artifact-bucket"
}

resource "aws_s3_bucket_acl" "codepipeline_bucket_acl" {
  bucket = aws_s3_bucket.codepipeline_bucket.id
  acl    = "private"
}

resource "aws_iam_role" "codepipeline-service-role" {
  name               = "arev-tf-cp2-cp-role"
  assume_role_policy = data.aws_iam_policy_document.assume-codepipeline-policy.json
}

data "aws_iam_policy_document" "assume-codepipeline-policy" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["codepipeline.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "codepipeline_policy" {
  name = "codepipeline_policy"
  role = aws_iam_role.codepipeline-service-role.id

  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect":"Allow",
      "Action": [
        "s3:GetObject",
        "s3:GetObjectVersion",
        "s3:GetBucketVersioning",
        "s3:PutObjectAcl",
        "s3:PutObject"
      ],
      "Resource": [
        "${aws_s3_bucket.codepipeline_bucket.arn}",
        "${aws_s3_bucket.codepipeline_bucket.arn}/*"
      ]
    },
    {
      "Effect": "Allow",
      "Action": [
        "codestar-connections:UseConnection"
      ],
      "Resource": "${aws_codestarconnections_connection.arev-tf-cp2-connection.id}"
    },
    {
      "Effect": "Allow",
      "Action": [
        "codebuild:BatchGetBuilds",
        "codebuild:StartBuild"
      ],
      "Resource": "*"
    }
  ]
}
EOF
}


/* ------ CodeStar Connection ------ */
resource "aws_codestarconnections_connection" "arev-tf-cp2-connection" {
  name          = "arev-tf-cp2-cs-connection"
  provider_type = "GitHub"
}


# Providing a reference to our default VPC
resource "aws_default_vpc" "default_vpc" {
}

# Providing a reference to our default subnets
resource "aws_default_subnet" "default_subnet_a" {
  availability_zone = "us-west-2a"
}

resource "aws_default_subnet" "default_subnet_b" {
  availability_zone = "us-west-2b"
}

resource "aws_default_subnet" "default_subnet_c" {
  availability_zone = "us-west-2c"
}


resource "aws_ecs_cluster" "arev-tf-cp2-cluster" {
  name = "arev-tf-cp2-cluster" # Naming the cluster
}

resource "aws_ecs_task_definition" "arev-tf-cp2-task" {
  family                   = "arev-tf-cp2-task" # Naming our first task
  container_definitions    = <<DEFINITION
  [
    {
      "name": "arev-tf-cp2-task",
      "image": "${aws_ecr_repository.arev-tf-cp2-ecr-repo.repository_url}",
      "essential": true,
      "portMappings": [
        {
          "containerPort": 3000,
          "hostPort": 3000
        }
      ],
      "memory": 512,
      "cpu": 256
    }
  ]
  DEFINITION
  requires_compatibilities = ["FARGATE"] # Stating that we are using ECS Fargate
  network_mode             = "awsvpc"    # Using awsvpc as our network mode as this is required for Fargate
  memory                   = 512         # Specifying the memory our container requires
  cpu                      = 256         # Specifying the CPU our container requires
  execution_role_arn       = aws_iam_role.ecsTaskExecutionRole.arn
}

# data "aws_iam_role" "ecsTaskExecutionRole" {
#   name = "ecsTaskExecutionRole"
# }

resource "aws_iam_role" "ecsTaskExecutionRole" {
  name               = "arevTaskExecutionRole"
  assume_role_policy = data.aws_iam_policy_document.assume_role_policy.json
}

data "aws_iam_policy_document" "assume_role_policy" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy_attachment" "ecsTaskExecutionRole_policy" {
  role       = aws_iam_role.ecsTaskExecutionRole.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_alb" "application_load_balancer" {
  name               = "arev-tf-cp2-alb" # Naming our load balancer
  load_balancer_type = "application"
  subnets = [ # Referencing the default subnets
    "${aws_default_subnet.default_subnet_a.id}",
    "${aws_default_subnet.default_subnet_b.id}",
    "${aws_default_subnet.default_subnet_c.id}"
  ]
  # Referencing the security group
  security_groups = ["${aws_security_group.load_balancer_security_group.id}"]
}

# Creating a security group for the load balancer:
resource "aws_security_group" "load_balancer_security_group" {
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # Allowing traffic in from all sources
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_lb_target_group" "target_group" {
  name        = "arev-tf-cp2-tg"
  port        = 80
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = aws_default_vpc.default_vpc.id # Referencing the default VPC
}

resource "aws_lb_listener" "listener" {
  load_balancer_arn = aws_alb.application_load_balancer.arn # Referencing our load balancer
  port              = "80"
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.target_group.arn # Referencing our target group
  }
}

resource "aws_ecs_service" "arev-tf-cp2_service" {
  name            = "arev-tf-cp2-service"                        # Naming our first service
  cluster         = aws_ecs_cluster.arev-tf-cp2-cluster.id       # Referencing our created Cluster
  task_definition = aws_ecs_task_definition.arev-tf-cp2-task.arn # Referencing the task our service will spin up
  launch_type     = "FARGATE"
  desired_count   = 3 # Setting the number of containers to 3

  load_balancer {
    target_group_arn = aws_lb_target_group.target_group.arn # Referencing our target group
    container_name   = aws_ecs_task_definition.arev-tf-cp2-task.family
    container_port   = 3000 # Specifying the container port
  }

  network_configuration {
    subnets          = ["${aws_default_subnet.default_subnet_a.id}", "${aws_default_subnet.default_subnet_b.id}", "${aws_default_subnet.default_subnet_c.id}"]
    assign_public_ip = true                                                # Providing our containers with public IPs
    security_groups  = ["${aws_security_group.service_security_group.id}"] # Setting the security group
  }
}


resource "aws_security_group" "service_security_group" {
  ingress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"
    # Only allowing traffic in from the load balancer security group
    security_groups = ["${aws_security_group.load_balancer_security_group.id}"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
