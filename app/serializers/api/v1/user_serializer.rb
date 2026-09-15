# frozen_string_literal: true

module Api
  module V1
    module UserSerializer
      class << self
        def list(user)
          {
            id: user.id,
            name: user.name,
            role: user.role,
            mobile: user.mobile,
            email: user.email,
            status: user.status,
            active: user.active?,
            managers: Array(user.managers).map { |manager| named_role(manager) }
          }
        end

        alias detail list

        private

        def named_role(user)
          { id: user.id, name: user.name, role: user.role }
        end
      end
    end
  end
end
