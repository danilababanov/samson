# frozen_string_literal: true

class Audit::UserPresenter
  ## User presenter for Audit Logger
  ## Returns user object with only id, email and name

  def self.present(user)
    if user
      {
          id: user.id,
          email: user.email,
          name: user.name
      }
    end
  end
end
