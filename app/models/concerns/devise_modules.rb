require 'active_support/concern'

module DeviseModules
  extend ActiveSupport::Concern

  included do

    devise :wolftech_authenticatable, :database_authenticatable, :registerable,
           :recoverable, :rememberable, :trackable, :validatable

  end
end
