class HomeController < ApplicationController
  before_action :require_organization!, only: [:demo_action]

  def index
  end

  def demo_action
    action_name = params[:action_name]
    permission = params[:permission]&.to_sym || :create_resources

    # Check permission using the organizations gem
    unless current_user.has_organization_permission_to?(permission)
      redirect_to root_path, alert: "Permission denied: Your role (#{current_user.current_organization_role}) lacks the :#{permission} permission. The organizations gem blocked this request."
      return
    end

    # Success case - show which permission allowed it
    action_labels = {
      "create_resource" => "Resource created!",
      "edit_resource" => "Resource updated!",
      "update_settings" => "Settings updated!",
      "update_billing" => "Billing updated!",
    }

    message = action_labels[action_name] || "Action completed!"
    redirect_to root_path, notice: "#{message} Your role (#{current_user.current_organization_role}) has the :#{permission} permission, so the gem allowed this action."
  end
end
