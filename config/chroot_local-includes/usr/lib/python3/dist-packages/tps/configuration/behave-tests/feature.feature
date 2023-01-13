@tags: @requires_mountpoint @requires_mock_service
Feature: Persistent Storage Features
  Test the activation of Persistent Storage features.

  Background:
    Given an unlocked Persistent Storage with an empty config file

    Scenario: Activating a feature with bind mounts
      Given a feature with bind mounts
      When the feature is activated
      Then the feature is active
      And the bind mounts are active

    Scenario: Activating a feature with inconsistent state
      Given a feature with bind mounts
      And the feature is enabled in the config file
      When the feature is activated
      Then the feature is active
      And the bind mounts are active
