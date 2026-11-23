# -----------------------------------------------------------------------------
# Monthly cost budget with email alerts.
# Covers the whole AWS account. It only alerts; it never stops spending.
# -----------------------------------------------------------------------------

resource "aws_budgets_budget" "monthly" {
  name         = "uk-property-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_cost_limit)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # Early warning: real spend passed 30% of the limit.
  notification {
    comparison_operator        = "GREATER_THAN"
    notification_type          = "ACTUAL"
    threshold                  = 30
    threshold_type             = "PERCENTAGE"
    subscriber_email_addresses = [var.budget_notification_email]
  }

  # Real spend passed 50% of the limit.
  notification {
    comparison_operator        = "GREATER_THAN"
    notification_type          = "ACTUAL"
    threshold                  = 50
    threshold_type             = "PERCENTAGE"
    subscriber_email_addresses = [var.budget_notification_email]
  }

  # AWS predicts the month will end over the limit, based on the spending trend.
  # Fires before the money is spent, unlike the ACTUAL alerts above.
  notification {
    comparison_operator        = "GREATER_THAN"
    notification_type          = "FORECASTED"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    subscriber_email_addresses = [var.budget_notification_email]
  }
}
