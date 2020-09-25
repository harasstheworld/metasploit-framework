# -*- coding: binary -*-

require 'metasploit/framework/hashes/identify'

module Msf
  ###
  #
  # This module provides methods for working with VyOS equipment
  #
  ###
  module Auxiliary::VYOS
    include Msf::Auxiliary::Report

    def vyos_config_eater(thost, tport, config, store = true)

      credential_data = {
        address: thost,
        port: tport,
        protocol: 'tcp',
        workspace_id: myworkspace.id,
        origin_type: :service,
        private_type: :nonreplayable_hash,
        # jtr_format: 'sha512,crypt', # default on the devices 11.4.0+
        service_name: '',
        module_fullname: fullname,
        status: Metasploit::Model::Login::Status::UNTRIED
      }

      # Default SNMP to UDP
      if tport == 161
        credential_data[:protocol] = 'udp'
      end

      if store && !config.include?('such file or directory') && !config.include?('ermission denied')
        l = store_loot('vyos.config', 'text/plain', thost, config.strip, 'config.txt', 'VyOS Configuration')
        vprint_good("#{thost}:#{tport} Config saved to: #{l}")
      end

      host_info = {
        host: thost,
        os_name: 'VyOS'
      }
      report_host(host_info)

      # generated by: cat /config/config.boot
      # https://github.com/rapid7/metasploit-framework/issues/14124

      # login {
      #    user jsmith {
      #        authentication {
      #            encrypted-password $6$ELBrDuW7c/8$nN7MwUST8s8O0R6HMNu/iPoTQ1s..y8HTnXraJ7Hh4bHefRmjt/2U08ZckEw4FU034wbWaeCaB5hq7mC6fNXl/
      #            plaintext-password ""
      #        }
      #        full-name "John Smith"
      #        level operator
      #    }
      #    user vyos {
      #        authentication {
      #            encrypted-password $1$5HsQse2v$VQLh5eeEp4ZzGmCG/PRBA1
      #            plaintext-password ""
      #        }
      #        level admin
      #    }
      # }

      # sometimes the hash is masked

      # login {
      #   user vyos {
      #        authentication {
      #            encrypted-password ****************
      #            plaintext-password ""
      #        }
      #        level admin
      #    }
      # }

      # plaintext-password can also be missing: https://github.com/rapid7/metasploit-framework/pull/14161#discussion_r492884039

      # in >= 1.3 'level' is no longer included and defaults to admin.

      r =  'user ([^ ]+) {\s*authentication {\s*'
      r << 'encrypted-password (\$?[\w$\./\*]*)\s*' # leading $ is optional incase the password is all stars
      r << '(?:plaintext-password "([^"]*)")?\s*' # optional
      r << '}'
      r << '(?:\s*full-name "([^"]*)")?\s*' # optional
      r << '(?:level (operator|admin))?' # 1.3+ seems to have removed operator
      config.scan(/#{Regexp.new(r)}/mi).each do |result|
        username = result[0].strip
        hash = result[1].strip
        # full-name is an optional field
        # we label it, but dont actually use it.  Maybe future expansion?
        unless result[3].nil?
          name = result[3].strip
        end
        if result[4].nil?
          level = 'admin'
        else
          level = result[4].strip
        end
        cred = credential_data.dup
        cred[:username] = username
        unless hash.start_with?('********') # if not in config mode these are masked
          cred[:jtr_format] = identify_hash(hash)
          cred[:private_data] = hash
          print_hash = " with hash #{hash}"
        end
        cred[:access_level] = level
        create_credential_and_login(cred) if framework.db.active
        unless result[2].to_s.strip.empty?
          plaintext = result[2].strip
          cred[:jtr_format] = ''
          cred[:private_type] = :password
          cred[:private_data] = plaintext
          create_credential_and_login(cred) if framework.db.active
          print_hash = "with password #{plaintext}"
        end
        print_good("#{thost}:#{tport} Username '#{username}' with level '#{level}'#{print_hash}")
      end

      # generated by: cat /config/config.boot

      # service {
      #    snmp {
      #      community ro {
      #        authorization ro
      #      }
      #      community write {
      #        authorization rw
      #      }
      #    }
      #  }

      config.scan(/community (\w+) {\n\s+authorization (ro|rw)/).each do |result|
        cred = credential_data.dup
        cred[:port] = 161
        cred[:protocol] = 'udp'
        cred[:service_name] = 'snmp'
        cred[:jtr_format] = ''
        cred[:private_data] = result[0].strip
        cred[:private_type] = :password
        cred[:access_level] = result[1].strip
        create_credential_and_login(cred) if framework.db.active
        print_good("#{thost}:#{tport} SNMP Community '#{result[0].strip}' with #{result[1].strip} access")
      end

      # generated by: cat /config/config

      # host-name vyos

      # interfaces {
      #     ethernet eth0 {
      #         duplex auto
      #         hw-id 00:0c:29:c7:af:bc
      #         smp_affinity auto
      #         speed auto
      #     }
      #     ethernet eth0 {
      #         address 1.1.1.1/8
      #         hw-id 00:0c:29:c7:af:cc
      #     }
      #     loopback lo {
      #     }
      # }

      # /* Release version: VyOS 1.1.8 */
      # // Release version: VyOS 1.3-rolling-202008270118

      if /host-name (.+)\n/ =~ config
        print_good("#{thost}:#{tport} Hostname: #{$1.strip}")
        host_info[:name] = $1.strip
        report_host(host_info) if framework.db.active
      end

      if %r{^/[/\*]\s?Release version: ([\w \.-]+)} =~ config
        print_good("#{thost}:#{tport} OS Version: #{$1.strip}")
        host_info[:os_flavor] = $1.strip
        report_host(host_info) if framework.db.active
      end

      #config.scan(%r{ethernet (eth\d{1,3}) {[\w\s":-]+(?:address ([\d\.]{6,16}/\d{1,2})[\w\s:-]+)?(?:description "?([\w\.\_\s]+)"?[\w\s:-]+)?hw-id (\w{2}:\w{2}:\w{2}:\w{2}:\w{2}:\w{2})[\w\s:-]+}}).each do |result|
      r =  'ethernet (eth\d{1,3}) {[\w\s":-]+'
      r << '(?:address ([\d\.]{6,16}/\d{1,2})[\w\s:-]+)?'
      r << '(?:description ["\']?([\w\.\_\s]+)["\']?[\w\s:-]+)?'
      r << 'hw-id (\w{2}:\w{2}:\w{2}:\w{2}:\w{2}:\w{2})[\w\s:-]+'
      r << '}'
      config.scan(/#{Regexp.new(r)}/i).each do |result|
        name = result[0].strip
        mac = result[3].strip
        host_info[:mac] = mac
        output = "#{thost}:#{tport} Interface #{name} (#{mac})"

        # static IP address
        unless result[1].nil?
          ip = result[1].split('/')[0].strip
          host_info[:host] = ip
          output << " - #{ip}"
        end

        # description
        unless result[2].nil?
          output << " with description: #{result[2].strip}"
        end
        report_host(host_info) if framework.db.active
        print_good(output)
      end

      # https://docs.vyos.io/en/crux/interfaces/wireless.html

      # server has type 'access-point', client is 'station'

      # interfaces {
      #  wireless wlan0 {
      #        address 192.168.2.1/24
      #        channel 1
      #        mode n
      #        security {
      #            wpa {
      #                cipher CCMP
      #                mode wpa2
      #                passphrase "12345678"
      #            }
      #        }
      #        ssid "TEST"
      #        type access-point
      #    }
      #}

      config.scan(/wireless (wlan\d{1,3}) {\s+.+passphrase "([^\n"]+)"\s+.+ssid ["']?([^\n"]+)["']?\s+type (access-point|station)/mi).each do |result|
        device = result[0].strip
        password = result[1].strip
        ssid = result[2].strip
        type = result[3].strip
        cred = credential_data.dup
        cred[:port] = 1
        cred[:protocol] = 'tcp'
        type == 'access-point' ? cred[:service_name] ='wireless AP' : cred[:service_name] ='wireless'
        cred[:jtr_format] = ''
        cred[:private_data] = password
        cred[:username] = ssid
        cred[:private_type] = :password
        create_credential_and_login(cred) if framework.db.active
        print_good("#{thost}:#{tport} Wireless #{type} '#{ssid}' with password: #{password}")
      end

      # wireless (server) with radius

      # interfaces {
      #  wireless wlan0 {
      #        address 192.168.2.1/24
      #        channel 1
      #        mode n
      #        security {
      #            wpa {
      #                cipher CCMP
      #                mode wpa2
      #                radius {
      #                    server 192.168.3.10 {
      #                        key 'VyOSPassword'
      #                        port 1812
      #                    }
      #                }
      #            }
      #        }
      #        ssid "Enterprise-TEST"
      #        type access-point
      #    }
      # }

      r =  'wireless (wlan\d{1,3}) {\s*'
      r << '.+radius {\s+'
      r << 'server ([^\s]+) {\s*'
      r << 'key [\'"]?([^\n"]+)[\'"]?\s*'
      r << 'port (\d{1,5})\s*'
      r << '.+ssid [\'"]?([^\n"\']+)[\'"]?\s*'
      r << 'type (access-point|station)'

      #config.scan(/#{Regexp.new(r)}/mi).each do |result|
      config.scan(/wireless (wlan\d{1,3}) {\s*.+radius {\s+server ([^\s]+) {\s*key ['"]?([^\n"']+)['"]?\s*port (\d{1,5})\s*.+ssid ['"]?([^\n"']+)['"]?\s*type (access-point|station)/mi).each do |result|
        device = result[0].strip
        server = result[1].strip
        password = result[2].strip
        server_port = result[3].strip
        ssid = result[4].strip
        type = result[5].strip
        cred = credential_data.dup
        cred[:port] = 1
        cred[:protocol] = 'tcp'
        type == 'access-point' ? cred[:service_name] ='wireless AP' : cred[:service_name] ='wireless'
        cred[:jtr_format] = ''
        cred[:private_data] = password
        cred[:username] = ssid
        cred[:private_type] = :password
        create_credential_and_login(cred) if framework.db.active
        print_good("#{thost}:#{tport} Wireless #{type} '#{ssid}' with radius password: #{password} to #{server}#{server_port}")
      end

      # https://docs.vyos.io/en/crux/services/ipoe-server.html#radius-setup

      # https://docs.vyos.io/en/crux/services/webproxy.html#authentication

      # https://docs.vyos.io/en/crux/vpn/pptp.html#server-example

      # https://docs.vyos.io/en/crux/interfaces/l2tpv3.html#l2tpv3-over-ipsec-l2-vpn-bridge

      # https://docs.vyos.io/en/crux/interfaces/pppoe.html#pppoe

      # /config/auth/ldap-auth.config

    end
  end
end
