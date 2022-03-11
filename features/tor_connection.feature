@product
Feature: Tor Connection helps the user in connecting to Tor
    As a Tails user
    I want to use Tor

    Background:
        Given I have started Tails from DVD without network and logged in

    # Scenario: Starting Tor Connection before connecting to wifi
    #     When I start "Tor Connection" via GNOME Activities Overview
    #     Then the Tor Connection Assistant reports that I am not connected to a local network

    # # this is not great, but it's the current status
    # Scenario: switching to a network with no Internet doesn't yield any error message
    #     Given the network is plugged
    #     And Tor is ready
    #     And I close "Tor Connection"
    #     When the network is unplugged
    #     And the Tor network and default bridges are blocked
    #     And I start "Tor Connection" via GNOME Activities Overview
    #     Then "Tor Connection" shows the success screen

    # Scenario: Close Tor Connection and open again
    #     Given Tor is ready
    #     When I close "Tor Connection"
    #     And I start "Tor Connection" via GNOME Activities Overview
    #     Then "Tor Connection" shows the success screen
