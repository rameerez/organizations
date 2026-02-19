class ApplicationController < ActionController::Base
  include Organizations::Controller

  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  # allow_browser versions: :modern

  helper_method :current_user, :demo_users

  def current_user
    @current_user ||= begin
      if session[:demo_user_id]
        User.find_by(id: session[:demo_user_id])
      end || create_default_demo_user
    end
  end

  def demo_users
    User.order(:created_at)
  end

  def switch_user
    if params[:email].present?
      # Switch to existing user or create new one
      user = User.find_or_create_by(email: params[:email].downcase.strip)
      session[:demo_user_id] = user.id
      # Clear organization session when switching users
      session.delete(:current_organization_id)
      redirect_to root_path, notice: "Switched to #{user.email}"
    else
      redirect_to root_path, alert: "Email required"
    end
  end

  def reset_demo!
    # Delete all demo data
    Organizations::Invitation.delete_all
    Organizations::Membership.delete_all
    Organizations::Organization.delete_all
    User.delete_all

    # Clear session
    session.delete(:demo_user_id)
    session.delete(:current_organization_id)
    @current_user = nil

    redirect_to root_path, notice: "Demo reset! All users and organizations deleted."
  end

  private

  def create_default_demo_user
    short_id = Digest::SHA256.hexdigest(session.id.to_s)[0, 6]
    user = User.find_or_create_by(email: "demo-#{short_id}@example.com") do |u|
      u.name = "Demo User #{short_id.upcase}"
    end
    session[:demo_user_id] = user.id
    user
  end
end
