@product
Feature: Localization
  As a Tails user
  I want Tails to be localized in my native language
  And various Tails features should still work

  @doc @not_release_blocker
  Scenario: The Report an Error launcher opens the support documentation in supported non-English locales
    Given I have started Tails from DVD without network and stopped at Tails Greeter's login screen
    And I log in to a new session in German (de)
    When I double-click on the Report an Error launcher on the desktop
    Then the support documentation page opens in Tor Browser

  @doc @slow @not_release_blocker
  Scenario Outline: Tails is localized for every tier-1 language
    Given I have started Tails from DVD without network and stopped at Tails Greeter's login screen
    When I log in to a new session in <language> (<lang_code>)
    Then the keyboard layout is set to "<layout>"
    When the network is plugged
    And Tor is ready
    Then I successfully start the Unsafe Browser in "<lang_code>"
    And I kill the Unsafe Browser
    When I enable the screen keyboard
    Then the screen keyboard works in Tor Browser
    And DuckDuckGo is the default search engine
    And I kill the Tor Browser
    And the screen keyboard works in Thunderbird
    And the layout of the screen keyboard is set to "<osk_layout>"

    # This list has to be kept in sync' with our list of tier-1 languages:
    #   https://tails.net/contribute/how/translate/#tier-1-languages

    # Known issues, that this step effectively verifies are still present:
    #  - Not all localized layouts exist in the GNOME screen keyboard: #8444
    #  - Arabic's layout should be "ara": #12638
    Examples:
      | language   | layout | osk_layout | lang_code |
      | Arabic     | us     | us         | ar    |
      | Chinese    | cn     | us         | zh_CN |
      | English    | us     | us         | en    |
      | French     | fr     | fr         | fr    |
      | German     | de     | de         | de    |
    # Tests disabled due to #18076
    # | Hindi      | in     | us         | hi    |
    # | Indonesian | id     | us         | id    |
      | Italian    | it     | us         | it    |
      | Persian    | ir     | ir         | fa    |
      | Portuguese | pt     | us         | pt    |
      | Russian    | ru     | ru         | ru    |
      | Spanish    | es     | us         | es    |
      | Turkish    | tr     | us         | tr    |
