When /^I start Tails' custom backup tool$/ do
  step 'I start "Persistent Storage Backup" via GNOME Activities Overview'
end

Then /^the backup tool displays "([^"]+)"$/ do |expected|
  message = Dogtail::Application.new('zenity')
              .child(roleName: 'label', retry: false).text
  assert(message[expected])
end

When /^I click "([^"]+)" in the backup tool$/ do |node|
  Dogtail::Application.new('zenity').child(node).click
end

When /^I enter my persistent storage passphrase into the polkit prompt$/ do
  deal_with_polkit_prompt(@persistence_password)
end
