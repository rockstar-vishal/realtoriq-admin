# frozen_string_literal: true

namespace :admin do
  desc "Create or update a platform admin (ADMIN_EMAIL, optional ADMIN_NAME, ADMIN_PASSWORD)"
  task create: :environment do
    email = ENV["ADMIN_EMAIL"].presence ||
      abort("Set ADMIN_EMAIL, e.g. ADMIN_EMAIL=you@example.com bin/rails admin:create")

    name = ENV["ADMIN_NAME"].presence || email.split("@").first.tr("._-", " ").titleize

    # Generated rather than defaulted. A known default password on an admin
    # account is exactly the kind of thing that survives all the way to
    # production, so there isn't one to inherit.
    generated = ENV["ADMIN_PASSWORD"].blank?
    password = ENV["ADMIN_PASSWORD"].presence || SecureRandom.alphanumeric(20)

    admin = AdminUser.find_or_initialize_by(email: email.downcase.strip)
    existed = admin.persisted?

    admin.name = name
    admin.password = password
    admin.active = true

    unless admin.save
      abort("Couldn't save that admin: #{admin.errors.full_messages.to_sentence}")
    end

    puts existed ? "Updated admin #{admin.email}" : "Created admin #{admin.email}"

    if generated
      puts <<~CREDENTIALS

        Password: #{password}

        Shown once and never recoverable — store it in a password manager now.
        Re-run this task with the same ADMIN_EMAIL to set a new one.
      CREDENTIALS
    end

    puts "\nSign in at /admin"
  end

  desc "List platform admins"
  task list: :environment do
    admins = AdminUser.order(:email)

    if admins.none?
      puts "No admins yet. Create one with:"
      puts "  ADMIN_EMAIL=you@example.com bin/rails admin:create"
      next
    end

    puts format("%-34s %-22s %-8s %s", "EMAIL", "NAME", "ACTIVE", "LAST LOGIN")
    admins.each do |admin|
      puts format(
        "%-34s %-22s %-8s %s",
        admin.email, admin.name, admin.active? ? "yes" : "no",
        admin.last_login_at&.strftime("%d %b %Y %H:%M") || "never"
      )
    end
  end

  desc "Deactivate an admin without deleting them (ADMIN_EMAIL)"
  task deactivate: :environment do
    email = ENV["ADMIN_EMAIL"].presence || abort("Set ADMIN_EMAIL")
    admin = AdminUser.find_by(email: email.downcase.strip) || abort("No admin with that email")

    # Their live sessions go too, otherwise an open browser keeps working until
    # its cookie expires.
    admin.update!(active: false)
    admin.admin_sessions.destroy_all

    puts "Deactivated #{admin.email} and ended their sessions."
  end
end
