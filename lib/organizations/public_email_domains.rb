# frozen_string_literal: true

module Organizations
  # Common free email providers, for config.blocked_email_domains. Opt-in:
  #
  #   config.blocked_email_domains = Organizations::PUBLIC_EMAIL_DOMAINS
  #   config.blocked_email_domains = Organizations::PUBLIC_EMAIL_DOMAINS + ["example-isp.net"]
  #
  # Defence in depth, not proof of authority and not a complete list: the
  # proof is the DNS challenge. A blocked domain cannot be enrolled and never
  # admits through a domain. People with these addresses can still join by
  # invitation, code or allowlist.
  PUBLIC_EMAIL_DOMAINS = %w[
    aol.com
    fastmail.com
    gmail.com
    gmx.com
    gmx.de
    gmx.net
    googlemail.com
    hey.com
    hotmail.co.uk
    hotmail.com
    hotmail.es
    hotmail.fr
    icloud.com
    live.com
    mac.com
    mail.com
    mail.ru
    me.com
    msn.com
    outlook.com
    outlook.es
    pm.me
    proton.me
    protonmail.com
    qq.com
    tutanota.com
    web.de
    yahoo.co.uk
    yahoo.com
    yahoo.es
    yahoo.fr
    yandex.com
    yandex.ru
    zoho.com
  ].freeze
end
