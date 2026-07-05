enum ConfigEnum {
  /// app update
  firstOpenInited('firstOpenInited'),
  renameDownloadMetadata('renameDownloadMetadata'),
  migrateGalleryHistory('migrateGalleryHistory'),
  migrateStorageConfig('migrateStorageConfig'),
  migrateLocalConfigUtimeToUtc('migrateLocalConfigUtimeToUtc'),
  migrateHistoryTimeToUtc('migrateHistoryTimeToUtc'),

  /// oplog-based cloud sync (format v2) state
  syncDeviceId('syncDeviceId'),
  oplogPushCursor('oplogPushCursor'),
  oplogAppliedOps('oplogAppliedOps'),
  oplogAppliedSnapshot('oplogAppliedSnapshot'),

  /// settings
  favoriteSetting('favoriteSetting'),
  advancedSetting('advancedSetting'),
  downloadSetting('downloadSetting'),
  EHSetting('EHSetting'),
  mouseSetting('mouseSetting'),
  networkSetting('networkSetting'),
  performanceSetting('performanceSetting'),
  preferenceSetting('preferenceSetting'),
  readSetting('readSetting'),
  securitySetting('securitySetting'),
  siteSetting('siteSetting'),
  styleSetting('styleSetting'),
  superResolutionSetting('SuperResolutionSetting'),
  userSetting('userSetting'),
  archiveBotSetting('archiveBotSetting'),
  webdavSetting('webdavSetting'),
  syncSetting('syncSetting'),
  keyboardShortcutSetting('keyboardShortcutSetting'),
  downloadSearchPageType('downloadSearchPageType'),
  windowFullScreen('windowFullScreen'),
  windowMaximize('windowMaximize'),
  windowWidth('windowWidth'),
  windowHeight('windowHeight'),
  leftColumnWidthRatio('leftColumnWidthRatio'),

  /// config
  ehCookie('eh_cookies'),
  searchConfig('searchConfig'),
  dismissVersion('dismissVersion'),
  readIndexRecord('readIndexRecord'),
  quickSearch('quickSearch'),
  oldGalleryHistory('history'),
  searchHistory('searchHistory'),
  nhentaiFavorite('nhentaiFavorite'),
  wnacgFavorite('wnacgFavorite'),
  myTagsSetting('MyTagsSetting'),
  builtInBlockedUser('builtInBlockedUser'),

  /// page config
  downloadPageBodyType('downloadPageGalleryType'),
  displayArchiveGroups('displayArchiveGroups'),
  displayGalleryGroups('displayGalleryGroups'),
  enableSearchHistoryTranslation('enableSearchHistoryTranslation'),
  tagTranslationServiceLoadingState('TagTranslationServiceLoadingState'),
  tagTranslationServiceTimestamp('TagTranslationServiceTimestamp'),
  tagSearchOrderOptimizationServiceVersion('TagTranslationServiceVersion'),
  tagSearchOrderOptimizationServiceLoadingState(
      'TagSearchOrderOptimizationServiceLoadingState'),
  displayBlockingRulesGroup('displayBlockingRulesGroup'),

  /// cache
  isSpreadPage('isSpreadPage'),
  galleryImageHash('galleryImageHash'),
  ;

  final String key;

  const ConfigEnum(this.key);

  static ConfigEnum from(String key) {
    return ConfigEnum.values.firstWhere((element) => element.key == key);
  }
}
