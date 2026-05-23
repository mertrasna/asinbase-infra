resource "aws_lb" "prod" {
  name               = "${local.name_prefix}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = [
    aws_subnet.public.id,   
    aws_subnet.public_b.id,
  ]

  enable_deletion_protection = false   # set to true once you're confident
  enable_http2               = true
  idle_timeout               = 60

  tags = {
    Name = "${local.name_prefix}-alb"
  }
}

resource "aws_lb_target_group" "prod" {
  name        = "${local.name_prefix}-tg"
  port        = 80
  protocol    = "HTTP"
  target_type = "instance"
  vpc_id      = aws_vpc.main.id

  health_check {
    enabled             = true
    path                = "/health"
    port                = "traffic-port"
    protocol            = "HTTP"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    matcher             = "200"
  }

  deregistration_delay = 30 # when removing a target, wait 30s  for in-flight requests to drain.

  tags = {
    Name = "${local.name_prefix}-tg"
  }
}

resource "aws_lb_target_group_attachment" "prod" {
  target_group_arn = aws_lb_target_group.prod.arn
  target_id        = aws_instance.prod.id
  port             = 80
}