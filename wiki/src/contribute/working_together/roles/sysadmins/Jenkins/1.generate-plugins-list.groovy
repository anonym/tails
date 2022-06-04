// Generate a list of latest plugin versions compatible with the current
// running Jenkins.
//
// This Groovy script can be run in the Jenkins Script Console, available at:
//
//     https://jenkins.tails.boum.org/script
//
// Output is one line per plugin, each with the following format:
//
//     name version [comma-separated list of dependencies]

initialList = [
  'build-symlink',
  'build-timeout',
  'cluster-stats',
  'conditional-buildstep',
  'copyartifact',
  'cucumber-reports',
  'email-ext',
  'envinject',
  'git',
  'git-client',
  'global-build-stats',
  'junit',
  'matrix-project',
  'parameterized-trigger',
  'postbuildscript',
  'PrioritySorter',
  'scoring-load-balancer',
  'scm-api',
  'timestamper',
  'ws-cleanup',
]

plugins = [:]

def getLatestInfo(shortName) {

  if (plugins.containsKey(shortName))
    return

  def plugin = Jenkins.instance.updateCenter.getPlugin(shortName)
  def version = plugin.version
  def deps = plugin.dependencies

  def depList = []
  deps.each { dep ->
    def depShortName = ''
    // Some dependencies are returned as hudson.PluginWrapper$Dependency
    // while others are java.util.HashMap$Node (no idea why!).
    if (dep.getClass() == hudson.PluginWrapper$Dependency) {
      depShortName = dep.shortName
    } else if (dep.getClass() == java.util.HashMap$Node) {
      depShortName = dep.getKey()
    }
    getLatestInfo(depShortName)
    depList.add(depShortName)
  }

  plugins.put(shortName, [
    'version': version,
    'dependencies': depList.toSet().sort()
  ])

}

initialList.each { shortName ->
  getLatestInfo(shortName)
}

for (key in plugins.keySet().sort{ it.toLowerCase() }) {
  println "${key} ${plugins[key]['version']} ${plugins[key]['dependencies']}"
}
