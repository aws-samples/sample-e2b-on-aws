// Graceful scale-in for the client pool.
//
// The lifecycle hook in main.tf holds a terminating client node in
// Terminating:Wait. What follows is what decides when to let it go: a Step
// Functions execution per node that marks it draining, heartbeats the hook, and
// completes the action once the node's sandbox count has been zero for long
// enough to be believed.
//
// Design and the reasoning behind every threshold:
// docs/design/client-node-graceful-scale-in.md

locals {
  drain_warden_name = "${var.prefix}-drain-warden"

  // Thresholds live in the state machine's Choice rules rather than in the
  // Lambda, so they are visible in each execution's history and can be changed
  // without a code deploy.
  //
  // 3900s = 65 min: tier base_v1 caps a sandbox at max_length_hours = 1, plus
  // five minutes of margin. Revisit if any tier is widened.
  drain_max_seconds = 3900
  // 600s: if the API cannot be reached to mark the node for ten minutes the
  // cluster is already unusable, and holding one termination open does not help.
  drain_unmarked_give_up_seconds = 600
  // 120s of quiet: 20s for the slowest api replica to stop placing
  // (cacheSyncTime) plus 60s for a create already in flight to finish or time out
  // (requestTimeout), plus margin.
  drain_quiet_seconds = 120
}

# =========================================================
# PACKAGING
# =========================================================

data "archive_file" "drain_warden_starter" {
  type        = "zip"
  source_file = "${path.module}/../lambda/drain-warden/starter.py"
  output_path = "${path.module}/.terraform/tmp/drain-warden-starter.zip"
}

data "archive_file" "drain_warden_step" {
  type        = "zip"
  source_file = "${path.module}/../lambda/drain-warden/drain_step.py"
  output_path = "${path.module}/.terraform/tmp/drain-warden-step.zip"
}

# =========================================================
# STARTER LAMBDA
# =========================================================

resource "aws_iam_role" "drain_warden_starter" {
  name = "${local.drain_warden_name}-starter"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy" "drain_warden_starter" {
  name = "${local.drain_warden_name}-starter"
  role = aws_iam_role.drain_warden_starter.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["states:StartExecution"]
        Resource = [aws_sfn_state_machine.drain_client_node.arn]
      },
      {
        // The reconciler asks which instances are waiting. Describe calls do not
        // take a resource condition on this API.
        Effect   = "Allow"
        Action   = ["autoscaling:DescribeAutoScalingGroups"]
        Resource = ["*"]
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = ["arn:aws:logs:${local.aws_region}:${local.account_id}:*"]
      },
    ]
  })
}

resource "aws_lambda_function" "drain_warden_starter" {
  function_name    = "${local.drain_warden_name}-starter"
  role             = aws_iam_role.drain_warden_starter.arn
  handler          = "starter.handler"
  runtime          = "python3.12"
  timeout          = 30
  filename         = data.archive_file.drain_warden_starter.output_path
  source_code_hash = data.archive_file.drain_warden_starter.output_base64sha256

  environment {
    variables = {
      ASG_NAME          = aws_autoscaling_group.client.name
      HOOK_NAME         = aws_autoscaling_lifecycle_hook.client_terminating.name
      STATE_MACHINE_ARN = aws_sfn_state_machine.drain_client_node.arn
    }
  }

  tags = local.common_tags
}

# =========================================================
# DRAIN-STEP LAMBDA
# =========================================================

resource "aws_iam_role" "drain_warden_step" {
  name = "${local.drain_warden_name}-step"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy" "drain_warden_step" {
  name = "${local.drain_warden_name}-step"
  role = aws_iam_role.drain_warden_step.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        // Only the admin token. Deliberately not the sandbox access token hash
        // seed, which used to be the same value and is now a separate secret so
        // that this role cannot read it.
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = [aws_secretsmanager_secret.admin_token.arn]
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = ["arn:aws:logs:${local.aws_region}:${local.account_id}:*"]
      },
    ]
  })
}

// Not in the VPC: the only dependencies are the internet-facing ALB, Secrets
// Manager and the Auto Scaling API. A VPC-attached function would need an ENI, a
// NAT route and a security group for nothing. If PublicAccess is ever Private
// the ALB becomes internal and this has to move into the private subnets, with a
// Secrets Manager VPC endpoint or a NAT route.
resource "aws_lambda_function" "drain_warden_step" {
  function_name    = "${local.drain_warden_name}-step"
  role             = aws_iam_role.drain_warden_step.arn
  handler          = "drain_step.handler"
  runtime          = "python3.12"
  timeout          = 60
  filename         = data.archive_file.drain_warden_step.output_path
  source_code_hash = data.archive_file.drain_warden_step.output_base64sha256

  environment {
    variables = {
      API_BASE           = "https://api.${var.domainname}"
      ADMIN_TOKEN_SECRET = aws_secretsmanager_secret.admin_token.name
    }
  }

  tags = local.common_tags
}

# =========================================================
# STATE MACHINE
# =========================================================

resource "aws_iam_role" "drain_client_node" {
  name = local.drain_warden_name

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "states.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy" "drain_client_node" {
  name = local.drain_warden_name
  role = aws_iam_role.drain_client_node.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["lambda:InvokeFunction"]
        Resource = [aws_lambda_function.drain_warden_step.arn]
      },
      {
        // Identified by instance id + hook + ASG rather than by
        // LifecycleActionToken, so an execution the reconciler started - which
        // never saw a token - behaves the same as one from the event.
        Effect = "Allow"
        Action = [
          "autoscaling:RecordLifecycleActionHeartbeat",
          "autoscaling:CompleteLifecycleAction",
        ]
        Resource = [aws_autoscaling_group.client.arn]
      },
    ]
  })
}

resource "aws_sfn_state_machine" "drain_client_node" {
  name     = local.drain_warden_name
  role_arn = aws_iam_role.drain_client_node.arn
  type     = "STANDARD"

  definition = jsonencode({
    Comment = "Drain a client node before its instance is terminated"
    StartAt = "Seed"
    // Backstop for the case the Choice cannot reach: a Lambda that fails to
    // invoke at all never returns elapsedSeconds, so nothing would evaluate the
    // give-up rules. On timeout the heartbeats stop and the hook releases the
    // instance within its own 300s.
    TimeoutSeconds = local.drain_max_seconds + 120

    States = {
      // Injects the execution start time once, so drain-step can return an
      // elapsed count and the Choice rules stay plain numeric comparisons.
      Seed = {
        Type = "Pass"
        Parameters = {
          "instanceId.$"         = "$.instanceId"
          "asgName.$"            = "$.asgName"
          "hookName.$"           = "$.hookName"
          "notFoundStreak.$"     = "$.notFoundStreak"
          "zeroStreak.$"         = "$.zeroStreak"
          "executionStartTime.$" = "$$.Execution.StartTime"
        }
        Next = "Heartbeat"
      }

      // First in the loop, so no retry or wait downstream can starve the hook.
      Heartbeat = {
        Type     = "Task"
        Resource = "arn:aws:states:::aws-sdk:autoscaling:recordLifecycleActionHeartbeat"
        Parameters = {
          "AutoScalingGroupName.$" = "$.asgName"
          "LifecycleHookName.$"    = "$.hookName"
          "InstanceId.$"           = "$.instanceId"
        }
        ResultPath = null
        // The hook may already have expired while the loop was running; that is
        // not a failure, there is simply nothing left to hold.
        Catch = [{
          ErrorEquals = ["States.ALL"]
          Next        = "Done"
        }]
        Next = "DrainStep"
      }

      DrainStep = {
        Type       = "Task"
        Resource   = aws_lambda_function.drain_warden_step.arn
        ResultPath = "$"
        Retry = [{
          ErrorEquals     = ["States.ALL"]
          IntervalSeconds = 5
          MaxAttempts     = 2
          BackoffRate     = 2
        }]
        // ResultPath on the catch keeps the loop's data; without it the error
        // object would replace the input and the next heartbeat would have no
        // instance id.
        Catch = [{
          ErrorEquals = ["States.ALL"]
          ResultPath  = "$.lambdaError"
          Next        = "WaitShort"
        }]
        Next = "Decide"
      }

      Decide = {
        Type = "Choice"
        Choices = [
          {
            // Three consecutive 404s: the node is gone rather than a replica
            // being briefly out of sync.
            Variable                 = "$.notFoundStreak"
            NumericGreaterThanEquals = 3
            Next                     = "Complete"
          },
          {
            Variable            = "$.elapsedSeconds"
            NumericGreaterThan  = local.drain_max_seconds
            Next                = "CompleteGaveUp"
          },
          {
            And = [
              { Variable = "$.marked", BooleanEquals = true },
              { Variable = "$.sandboxCount", NumericEquals = 0 },
              // Two consecutive zero reads on top of the quiet period, which also
              // covers the orchestrator's post-sandbox cleanup.
              { Variable = "$.zeroStreak", NumericGreaterThanEquals = 2 },
              { Variable = "$.quietSeconds", NumericGreaterThanEquals = local.drain_quiet_seconds },
            ]
            Next = "Complete"
          },
          {
            And = [
              { Variable = "$.marked", BooleanEquals = false },
              { Variable = "$.elapsedSeconds", NumericGreaterThanEquals = local.drain_unmarked_give_up_seconds },
            ]
            Next = "CompleteGaveUp"
          },
          {
            // Not yet marked: retry on a short loop so a transient API failure
            // costs seconds, not a minute.
            Variable      = "$.marked"
            BooleanEquals = false
            Next          = "WaitShort"
          },
        ]
        Default = "Wait"
      }

      Wait      = { Type = "Wait", Seconds = 60, Next = "Heartbeat" }
      WaitShort = { Type = "Wait", Seconds = 30, Next = "Heartbeat" }

      Complete = {
        Type     = "Task"
        Resource = "arn:aws:states:::aws-sdk:autoscaling:completeLifecycleAction"
        Parameters = {
          "AutoScalingGroupName.$"  = "$.asgName"
          "LifecycleHookName.$"     = "$.hookName"
          "InstanceId.$"            = "$.instanceId"
          "LifecycleActionResult"   = "CONTINUE"
        }
        ResultPath = null
        Catch = [{
          ErrorEquals = ["States.ALL"]
          Next        = "Done"
        }]
        End = true
      }

      // Same call, separate state: a give-up is visible as its own transition in
      // the execution history and can be alarmed on by name, instead of looking
      // identical to a clean drain.
      CompleteGaveUp = {
        Type     = "Task"
        Resource = "arn:aws:states:::aws-sdk:autoscaling:completeLifecycleAction"
        Parameters = {
          "AutoScalingGroupName.$"  = "$.asgName"
          "LifecycleHookName.$"     = "$.hookName"
          "InstanceId.$"            = "$.instanceId"
          "LifecycleActionResult"   = "CONTINUE"
        }
        ResultPath = null
        Catch = [{
          ErrorEquals = ["States.ALL"]
          Next        = "GaveUp"
        }]
        Next = "GaveUp"
      }

      // Fails the execution on purpose: a give-up means an instance was released
      // with sandboxes possibly still on it, which is what the alarm on
      // ExecutionsFailed is for.
      GaveUp = {
        Type  = "Fail"
        Error = "DrainGaveUp"
        Cause = "Completed the lifecycle action without confirming the node was empty"
      }

      Done = { Type = "Succeed" }
    }
  })

  tags = local.common_tags
}

# =========================================================
# TRIGGERS
# =========================================================

// Undeliverable invocations land here rather than disappearing. Alarmed below.
resource "aws_sqs_queue" "drain_warden_dlq" {
  name                      = "${local.drain_warden_name}-dlq"
  message_retention_seconds = 1209600 # 14 days
  tags                      = local.common_tags
}

// Fast path.
resource "aws_cloudwatch_event_rule" "drain_warden_lifecycle" {
  name        = "${local.drain_warden_name}-lifecycle"
  description = "Client node entering Terminating:Wait"

  event_pattern = jsonencode({
    source      = ["aws.autoscaling"]
    detail-type = ["EC2 Instance-terminate Lifecycle Action"]
    detail = {
      AutoScalingGroupName = [aws_autoscaling_group.client.name]
    }
  })

  tags = local.common_tags
}

resource "aws_cloudwatch_event_target" "drain_warden_lifecycle" {
  rule = aws_cloudwatch_event_rule.drain_warden_lifecycle.name
  arn  = aws_lambda_function.drain_warden_starter.arn

  // A delivery retried past the hook's lifetime would only operate on an expired
  // action, so it is dropped to the DLQ instead.
  retry_policy {
    maximum_event_age_in_seconds = 240
    maximum_retry_attempts       = 3
  }

  dead_letter_config {
    arn = aws_sqs_queue.drain_warden_dlq.arn
  }
}

// Reconciler. Lifecycle action events are best-effort, and a missed one would
// otherwise end with the hook expiring and the node terminating with sandboxes on
// it. Two minutes keeps most of the 300s heartbeat window in reserve.
resource "aws_cloudwatch_event_rule" "drain_warden_reconcile" {
  name                = "${local.drain_warden_name}-reconcile"
  description         = "Catch client nodes whose lifecycle event was missed"
  schedule_expression = "rate(2 minutes)"
  tags                = local.common_tags
}

resource "aws_cloudwatch_event_target" "drain_warden_reconcile" {
  rule = aws_cloudwatch_event_rule.drain_warden_reconcile.name
  arn  = aws_lambda_function.drain_warden_starter.arn
}

resource "aws_lambda_permission" "drain_warden_lifecycle" {
  statement_id  = "AllowExecutionFromEventBridgeLifecycle"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.drain_warden_starter.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.drain_warden_lifecycle.arn
}

resource "aws_lambda_permission" "drain_warden_reconcile" {
  statement_id  = "AllowExecutionFromEventBridgeReconcile"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.drain_warden_starter.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.drain_warden_reconcile.arn
}

resource "aws_sqs_queue_policy" "drain_warden_dlq" {
  queue_url = aws_sqs_queue.drain_warden_dlq.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.drain_warden_dlq.arn
      Condition = {
        ArnEquals = { "aws:SourceArn" = aws_cloudwatch_event_rule.drain_warden_lifecycle.arn }
      }
    }]
  })
}

# =========================================================
# ALARMS
# =========================================================

// Without these the give-up paths are silent, and a give-up is the one outcome
// that means sandboxes may have been killed.
resource "aws_cloudwatch_metric_alarm" "drain_warden_failed" {
  alarm_name          = "${local.drain_warden_name}-executions-failed"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  threshold           = 0
  period              = 300
  namespace           = "AWS/States"
  metric_name         = "ExecutionsFailed"
  statistic           = "Sum"
  treat_missing_data  = "notBreaching"

  dimensions = {
    StateMachineArn = aws_sfn_state_machine.drain_client_node.arn
  }

  alarm_description = "A client node was released without confirming it was empty"
  tags              = local.common_tags
}

resource "aws_cloudwatch_metric_alarm" "drain_warden_timed_out" {
  alarm_name          = "${local.drain_warden_name}-executions-timed-out"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  threshold           = 0
  period              = 300
  namespace           = "AWS/States"
  metric_name         = "ExecutionsTimedOut"
  statistic           = "Sum"
  treat_missing_data  = "notBreaching"

  dimensions = {
    StateMachineArn = aws_sfn_state_machine.drain_client_node.arn
  }

  alarm_description = "A drain execution hit its own timeout"
  tags              = local.common_tags
}

resource "aws_cloudwatch_metric_alarm" "drain_warden_dlq" {
  alarm_name          = "${local.drain_warden_name}-dlq-not-empty"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  threshold           = 0
  period              = 300
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  statistic           = "Maximum"
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = aws_sqs_queue.drain_warden_dlq.name
  }

  alarm_description = "A lifecycle event could not be delivered to the starter"
  tags              = local.common_tags
}
