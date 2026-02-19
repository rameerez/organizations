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
    # Generate a realistic-looking name and email using Faker
    # Seed with session ID for consistency within the same session
    require 'faker' unless defined?(::Faker)

    seed = Digest::SHA256.hexdigest(session.id.to_s)[0, 8].to_i(16)
    ::Faker::Config.random = Random.new(seed)

    first_name = ::Faker::Name.first_name
    last_name = ::Faker::Name.last_name
    full_name = "#{first_name} #{last_name}"
    email = ::Faker::Internet.email(name: full_name, domain: 'example.com')

    user = User.find_or_create_by(email: email) do |u|
      u.name = full_name
    end
    session[:demo_user_id] = user.id
    user
  end
end
