@product @check_tor_leaks
Feature: Thunderbird email client
  As a Tails user
  I may want to use an email client

  Background:
    Given I have started Tails from DVD and logged in and the network is connected
    And I have not configured an email account yet
    When I start Thunderbird
    Then I am prompted to setup an email account

  Scenario: No add-ons are installed
    Given I cancel setting up an email account
    When I open Thunderbird's Add-ons Manager
    And I open the Extensions tab
    Then I see that no add-ons are enabled in Thunderbird
