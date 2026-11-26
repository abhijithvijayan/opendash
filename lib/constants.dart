const appName = 'OpenDash';
const appVersion = '0.3.8';
const repoUrl = 'github.com/abhijithvijayan/opendash';

/// Where OpenDash's own releases are published (`owner/repo` on GitHub).
/// It must be public: the app asks without a token. The release workflow
/// passes the repository it runs in (`--dart-define=RELEASES_REPO`), so a
/// fork's releases check the fork's own; any other build checks this one.
const releasesRepo = String.fromEnvironment('RELEASES_REPO', defaultValue: 'abhijithvijayan/opendash');
/// Where the anonymous weekly usage ping goes (`server/usage`). Empty: none
/// is sent. Given only to official releases, by the release workflow
/// (`--dart-define=USAGE_PING_URL`, from the repository's USAGE_PING_URL
/// secret): a fork or a local build counts nothing, anywhere.
const usagePingUrl = String.fromEnvironment('USAGE_PING_URL');
const ownPackage = 'in.abhijithvijayan.opendash';
const issuesUrl = '$repoUrl/issues';

/// The phone app that installs, updates and removes OpenDash, and sends it
/// updates when the scooter can't reach GitHub (the QR code's link). A fork
/// with its own companion sets the COMPANION_REPO repository variable.
const companionRepoUrl = 'github.com/${String.fromEnvironment('COMPANION_REPO', defaultValue: 'abhijithvijayan/opendash-companion')}';
const stockDashboardPackage = 'com.olaelectric.hmiclient';
const openHeadunitPackage = 'com.andrerinas.headunitrevived';
const diplayPackage = 'com.shihab.diplay';
