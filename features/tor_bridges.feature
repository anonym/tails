#11589
@product @fragile
Feature: Using Tails with Tor bridges and pluggable transports
  As a Tails user
  I want to circumvent censorship of Tor by using Tor bridges and pluggable transports
  And avoid connecting directly to the Tor Network

  Background:
    Given I have started Tails from DVD without network and logged in
    And I capture all network traffic
    When the network is plugged
    Then the Tor Connection Assistant autostarts

  Scenario: Using normal bridges
    When I configure some normal bridges in the Tor Connection Assistant
    Then Tor is ready
    And available upgrades have been checked
    And all Internet traffic has only flowed through the configured bridges

  Scenario: Using obfs4 pluggable transports
    When I configure some obfs4 bridges in the Tor Connection Assistant
    Then Tor is ready
    And available upgrades have been checked
    And all Internet traffic has only flowed through the configured bridges

  Scenario: Default Tor bridges
    When I configure the default bridges in the Tor Connection Assistant
    Then Tor is ready
    And Tor is configured to use the default bridges
    And available upgrades have been checked
    And all Internet traffic has only flowed through the configured bridges

  Scenario: Fall back to default bridges if failing to connect directly to the Tor network
    Given the Tor network is blocked
    When I configure a direct connection in the Tor Connection Assistant
    Then Tor is ready
    And available upgrades have been checked
    And Tor is configured to use the default bridges

  Scenario: TCA can reconnect after a connection failure
    Given the Tor network and default bridges are blocked
    When I try to configure a direct connection in the Tor Connection Assistant
    Then the Tor Connection Assistant reports that it failed to connect
    # TCA does not have a simple "retry" so we restart it
    And I close the Tor Connection Assistant
    # Before we unblock we must stop Tor from retrying, otherwise the
    # above first try might succeed, which isn't what we expect or
    # want to test here.
    And I set DisableNetwork=1 over Tor's control port
    Given the Tor network and default bridges are unblocked
    And I start "Tor Connection" via GNOME Activities Overview
    When I configure a direct connection in the Tor Connection Assistant
    Then Tor is ready
    And available upgrades have been checked

  Scenario: Normal bridges are not allowed in "Hide" mode
    When I try to configure some normal bridges in the Tor Connection Assistant in hide mode
    Then the Tor Connection Assistant complains that normal bridges are not allowed
    And I cannot click the "Connect to Tor" button

  Scenario: The same Tor configuration is applied when the network is reconnected
    Given I configure a direct connection in the Tor Connection Assistant
    And Tor is ready
    When I disconnect the network through GNOME
    And I connect the network through GNOME
    Then the Tor Connection Assistant autostarts
    And the Tor Connection Assistant connects to Tor
    And Tor is ready
    And Tor is using the same configuration as before
    And available upgrades have been checked
