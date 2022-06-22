@product
Feature: Using persistent Tor bridges and pluggable transports
  As a Tails user
  I want to save Tor bridges in Persistent Storage
  And be given the option to use them again

  Background:
    Given I start Tails from a freshly installed USB drive with an administration password and the network is plugged and I login
    And I create a persistent partition with the default settings
    And I cold reboot the computer
    And the computer reboots Tails
    And I enable persistence
    And I log in to a new session
    And /var/lib/tca is not configured to persist
    When the network is plugged
    And the Tor Connection Assistant autostarts
    And I configure some persistent obfs4 bridges in the Tor Connection Assistant
    And I wait until Tor is ready
    Then tca.conf includes the configured bridges
    And /var/lib/tca is configured to persist
    When I cold reboot the computer
    And the computer reboots Tails
    And I enable persistence
    And I capture all network traffic
    And I log in to a new session
    Then tca.conf includes the configured bridges
    When the network is plugged
    And the Tor Connection Assistant autostarts

  #18926
  @fragile
  Scenario: Using Persistent Tor bridges
    When I choose to connect to Tor automatically
    And I accept Tor Connection's offer to use my persistent bridges
    And I click "Connect to Tor"
    Then I wait until Tor is ready
    And tca.conf includes the configured bridges
    And /var/lib/tca is still configured to persist
    And all Internet traffic has only flowed through the configured bridges or connectivity check service

  #18926
  @fragile
  Scenario: Disabling persistence of Tor bridges
    When I choose to connect to Tor automatically
    And I accept Tor Connection's offer to use my persistent bridges
    And I disable saving bridges to Persistent Storage
    And I click "Connect to Tor"
    Then I wait until Tor is ready
    And tca.conf includes the configured bridges
    And /var/lib/tca is not configured to persist
    And all Internet traffic has only flowed through the configured bridges or connectivity check service
