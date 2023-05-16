require 'resolv'

When /^I (wget|curl) "([^"]+)" to stdout(?:| with the '([^']+)' options)$/ do |cmd, target, options|
  retry_tor do
    if target == 'some Tails mirror'
      host = 'dl.amnesia.boum.org'
      address = Resolv.new.getaddresses(host).sample
      puts "Resolved #{host} to #{address}"
      url = "http://#{address}/tails/stable/"
    else
      url = target
    end
    arguments = if cmd == 'wget'
                  "-O - '#{url}'"
                else
                  "-s '#{url}'"
                end
    arguments = "#{options} #{arguments}" if options
    @vm_execute_res = $vm.execute("#{cmd} #{arguments}", user: LIVE_USER)
    if @vm_execute_res.failure?
      raise "#{cmd}:ing #{url} with options #{options} failed with:\n" \
            "#{@vm_execute_res.stdout}\n" +
            @vm_execute_res.stderr.to_s
    end
  end
end

Then /^the (wget|curl) command is successful$/ do |cmd|
  assert(
    @vm_execute_res.success?,
    "#{cmd} failed:\n" \
    "#{@vm_execute_res.stdout}\n" +
    @vm_execute_res.stderr.to_s
  )
end

Then /^the (wget|curl) standard output contains "([^"]+)"$/ do |cmd, text|
  assert(
    @vm_execute_res.stdout[text],
    "The #{cmd} standard output does not contain #{text}:\n" \
    "#{@vm_execute_res.stdout}\n" +
    @vm_execute_res.stderr.to_s
  )
end
