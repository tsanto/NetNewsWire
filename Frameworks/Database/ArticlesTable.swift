//
//  ArticlesTable.swift
//  Evergreen
//
//  Created by Brent Simmons on 5/9/16.
//  Copyright © 2016 Ranchero Software, LLC. All rights reserved.
//

import Foundation
import RSCore
import RSDatabase
import RSParser
import Data

final class ArticlesTable: DatabaseTable {

	let name: String
	private weak var account: Account?
	private let queue: RSDatabaseQueue
	private let statusesTable = StatusesTable()
	private let authorsLookupTable: DatabaseLookupTable
	private let attachmentsLookupTable: DatabaseLookupTable
	private let tagsLookupTable: DatabaseLookupTable
	private let articleCache = ArticleCache()
	
	// TODO: update articleCutoffDate as time passes and based on user preferences.
	private var articleCutoffDate = NSDate.rs_dateWithNumberOfDays(inThePast: 3 * 31)!
	private var maximumArticleCutoffDate = NSDate.rs_dateWithNumberOfDays(inThePast: 4 * 31)!

	init(name: String, account: Account, queue: RSDatabaseQueue) {

		self.name = name
		self.account = account
		self.queue = queue

		let authorsTable = AuthorsTable(name: DatabaseTableName.authors)
		self.authorsLookupTable = DatabaseLookupTable(name: DatabaseTableName.authorsLookup, objectIDKey: DatabaseKey.articleID, relatedObjectIDKey: DatabaseKey.authorID, relatedTable: authorsTable, relationshipName: RelationshipName.authors)
		
		let tagsTable = TagsTable(name: DatabaseTableName.tags)
		self.tagsLookupTable = DatabaseLookupTable(name: DatabaseTableName.tags, objectIDKey: DatabaseKey.articleID, relatedObjectIDKey: DatabaseKey.tagName, relatedTable: tagsTable, relationshipName: RelationshipName.tags)
		
		let attachmentsTable = AttachmentsTable(name: DatabaseTableName.attachments)
		self.attachmentsLookupTable = DatabaseLookupTable(name: DatabaseTableName.attachmentsLookup, objectIDKey: DatabaseKey.articleID, relatedObjectIDKey: DatabaseKey.attachmentID, relatedTable: attachmentsTable, relationshipName: RelationshipName.attachments)
	}

	// MARK: Fetching
	
	func fetchArticles(_ feed: Feed) -> Set<Article> {
		
		let feedID = feed.feedID
		var articles = Set<Article>()

		queue.fetchSync { (database: FMDatabase!) -> Void in
			articles = self.fetchArticlesForFeedID(feedID, withLimits: true, database: database)
		}

		return articleCache.uniquedArticles(articles)
	}

	func fetchArticlesAsync(_ feed: Feed, withLimits: Bool, _ resultBlock: @escaping ArticleResultBlock) {

		let feedID = feed.feedID

		queue.fetch { (database: FMDatabase!) -> Void in

			let fetchedArticles = self.fetchArticlesForFeedID(feedID, withLimits: withLimits, database: database)

			DispatchQueue.main.async {
				let articles = self.articleCache.uniquedArticles(fetchedArticles)
				resultBlock(articles)
			}
		}
	}
	
	func fetchUnreadArticles(for feeds: Set<Feed>) -> Set<Article> {

		return fetchUnreadArticles(feeds.feedIDs())
	}

	// MARK: Updating
	
	func update(_ feed: Feed, _ parsedFeed: ParsedFeed, _ completion: @escaping RSVoidCompletionBlock) {

		if parsedFeed.items.isEmpty {
			completion()
			return
		}

		// 1. Ensure statuses for all the parsedItems.
		// 2. Fetch all articles for the feed.
		// 3. For each parsedItem:
		//	  - if userDeleted || (!starred && status.dateArrived < cutoff), then ignore
		//    - if matches existing article, then update database with changes between the two
		//    - if new, create article and save in database

		fetchArticlesAsync(feed, withLimits: false) { (articles) in
			self.updateArticles(articles.dictionary(), parsedFeed.itemsDictionary(with: feed), feed, completion)
		}
	}

	// MARK: Unread Counts
	
	func fetchUnreadCounts(_ feeds: Set<Feed>, _ completion: @escaping UnreadCountCompletionBlock) {
		
		let feedIDs = feeds.feedIDs()
		var unreadCountTable = UnreadCountTable()

		queue.fetch { (database) in

			for feedID in feedIDs {
				unreadCountTable[feedID] = self.fetchUnreadCount(feedID, database)
			}

			DispatchQueue.main.async() {
				completion(unreadCountTable)
			}
		}
	}

	// MARK: Status
	
	func mark(_ articles: Set<Article>, _ statusKey: String, _ flag: Bool) {
		
		// Sets flag in both memory and in database.
		
		let articleIDs = articles.flatMap { (article) -> String? in
			
			guard let status = article.status else {
				assertionFailure("Each article must have a status.")
				return nil
			}
			
			if status.boolStatus(forKey: statusKey) == flag {
				return nil
			}
			status.setBoolStatus(flag, forKey: statusKey)
			return article.articleID
		}
		
		if articleIDs.isEmpty {
			return
		}
		
		queue.update { (database) in
			self.statusesTable.markArticleIDs(Set(articleIDs), statusKey, flag, database)
		}
	}
}

// MARK: - Private

private extension ArticlesTable {

	// MARK: Fetching

	func attachRelatedObjects(_ articles: Set<Article>, _ database: FMDatabase) {

		let articleArray = articles.map { $0 as DatabaseObject }
		
		authorsLookupTable.attachRelatedObjects(to: articleArray, in: database)
		attachmentsLookupTable.attachRelatedObjects(to: articleArray, in: database)
		tagsLookupTable.attachRelatedObjects(to: articleArray, in: database)

		// In theory, it’s impossible to have a fetched article without a status.
		// Let’s handle that impossibility anyway.
		// Remember that, if nothing else, the user can edit the SQLite database,
		// and thus could delete all their statuses.

		statusesTable.ensureStatusesForArticles(articles, database)
	}

	func articleWithRow(_ row: FMResultSet) -> Article? {

		guard let account = account else {
			return nil
		}
		guard let article = Article(row: row, account: account) else {
			return nil
		}

		// Note: the row is a result of a JOIN query with the statuses table,
		// so we can get the status at the same time and avoid additional database lookups.

		article.status = statusesTable.statusWithRow(row)
		return article
	}

	func articlesWithResultSet(_ resultSet: FMResultSet, _ database: FMDatabase) -> Set<Article> {

		let articles = resultSet.mapToSet(articleWithRow)
		attachRelatedObjects(articles, database)
		return articles
	}

	func fetchArticlesWithWhereClause(_ database: FMDatabase, whereClause: String, parameters: [AnyObject], withLimits: Bool) -> Set<Article> {

		// Don’t fetch articles that shouldn’t appear in the UI. The rules:
		// * Must not be deleted.
		// * Must be either 1) starred or 2) dateArrived must be newer than cutoff date.

		let sql = withLimits ? "select * from articles natural join statuses where \(whereClause) and userDeleted=0 and (starred=1 or dateArrived>?);" : "select * from articles natural join statuses where \(whereClause);"
		return articlesWithSQL(sql, parameters + [articleCutoffDate as AnyObject], database)
	}

	func fetchUnreadCount(_ feedID: String, _ database: FMDatabase) -> Int {
		
		// Count only the articles that would appear in the UI.
		// * Must be unread.
		// * Must not be deleted.
		// * Must be either 1) starred or 2) dateArrived must be newer than cutoff date.

		let sql = "select count(*) from articles natural join statuses where feedID=? and read=0 and userDeleted=0 and (starred=1 or dateArrived>?);"
		return numberWithSQLAndParameters(sql, [feedID, articleCutoffDate], in: database)
	}
	
	func fetchArticlesForFeedID(_ feedID: String, withLimits: Bool, database: FMDatabase) -> Set<Article> {

		return fetchArticlesWithWhereClause(database, whereClause: "articles.feedID = ?", parameters: [feedID as AnyObject], withLimits: withLimits)
	}

	func fetchUnreadArticles(_ feedIDs: Set<String>) -> Set<Article> {

		if feedIDs.isEmpty {
			return Set<Article>()
		}

		var articles = Set<Article>()

		queue.fetchSync { (database) in

			// select * from articles natural join statuses where feedID in ('http://ranchero.com/xml/rss.xml') and read=0

			let parameters = feedIDs.map { $0 as AnyObject }
			let placeholders = NSString.rs_SQLValueList(withPlaceholders: UInt(feedIDs.count))!
			let whereClause = "feedID in \(placeholders) and read=0"
			articles = self.fetchArticlesWithWhereClause(database, whereClause: whereClause, parameters: parameters, withLimits: true)
		}

		return articleCache.uniquedArticles(articles)
	}

	func articlesWithSQL(_ sql: String, _ parameters: [AnyObject], _ database: FMDatabase) -> Set<Article> {

		guard let resultSet = database.executeQuery(sql, withArgumentsIn: parameters) else {
			return Set<Article>()
		}
		return articlesWithResultSet(resultSet, database)
	}

	// MARK: Saving/Updating

	func updateArticles(_ articlesDictionary: [String: Article], _ parsedItemsDictionary: [String: ParsedItem], _ feed: Feed, _ completion: @escaping RSVoidCompletionBlock) {

		// 1. Fetch statuses for parsedItems.
		// 2. Filter out parsedItems where userDeleted==1 or (arrival date > 4 months and not starred).
		// (Under no user setting do we retain articles older with an arrival date > 4 months.)
		// 3. Find parsedItems with no status and no matching article: save them as entirely new articles.
		// 4. Compare remaining parsedItems with articles, and update database with any changes.

		assert(Thread.isMainThread)

		queue.fetch { (database) in

			let parsedItemArticleIDs = Set(parsedItemsDictionary.keys)
			let fetchedStatuses = self.statusesTable.fetchStatusesForArticleIDs(parsedItemArticleIDs, database)

			DispatchQueue.main.async {

				// #2. Drop any parsedItems that can be ignored.
				// If that’s all of them, then great — nothing to do.
				let filteredParsedItems = self.filterParsedItems(parsedItemsDictionary, fetchedStatuses)
				if filteredParsedItems.isEmpty {
					completion()
					return
				}

				// #3. Save entirely new parsedItems.
				let newParsedItems = self.findNewParsedItems(parsedItemsDictionary, fetchedStatuses, articlesDictionary)
				if !newParsedItems.isEmpty {
					self.saveNewParsedItems(newParsedItems, feed)
				}

				// #4. Update existing parsedItems.
				let parsedItemsToUpdate = self.findExistingParsedItems(parsedItemsDictionary, fetchedStatuses, articlesDictionary)
				if !parsedItemsToUpdate.isEmpty {
					self.updateParsedItems(parsedItemsToUpdate, articlesDictionary, feed)
				}

				completion()
			}
		}
	}

	func updateParsedItems(_ parsedItems: [String: ParsedItem], _ articles: [String: Article], _ feed: Feed) {

		assert(Thread.isMainThread)

		updateRelatedObjects(_ parsedItems: [String: ParsedItem], _ articles: [String: Article])

	}

	func updateRelatedObjects(_ parsedItems: [String: ParsedItem], _ articles: [String: Article]) {

		// Update the in-memory Articles when needed.
		// Save only when there are changes, which should be pretty infrequent.

		assert(Thread.isMainThread)

		var articlesWithTagChanges = Set<Article>()
		var articlesWithAttachmentChanges = Set<Article>()
		var articlesWithAuthorChanges = Set<Article>()

		for (articleID, parsedItem) in parsedItems {

			guard let article = articles[articleID] else {
				continue
			}

			if article.updateTagsWithParsedTags(parsedItem.tags) {
				articlesWithTagChanges.insert(article)
			}
			if article.updateAttachmentsWithParsedAttachments(parsedItem.attachments) {
				articlesWithAttachmentChanges.insert(article)
			}
			if article.updateAuthorsWithParsedAuthors(parsedItem.authors) {
				articlesWithAuthorChanges.insert(article)
			}
		}

		if articlesWithTagChanges.isEmpty && articlesWithAttachmentChanges.isEmpty && articlesWithAuthorChanges.isEmpty {
			// Should be pretty common.
			return
		}

		// We used detachedCopy because the Article objects being updated are main-thread objects.
		
		articlesWithTagChanges = Set(articlesWithTagChanges.map{ $0.detachedCopy() })
		articlesWithAttachmentChanges = Set(articlesWithAttachmentChanges.map{ $0.detachedCopy() })
		articlesWithAuthorChanges = Set(articlesWithAuthorChanges.map{ $0.detachedCopy() })

		queue.update { (database) in
			if !articlesWithTagChanges.isEmpty {
				tagsLookupTable.saveRelatedObjects(for: articlesWithTagChanges.databaseObjects(), in: database)
			}
			if !articlesWithAttachmentChanges.isEmpty {
				attachmentsLookupTable.saveRelatedObjects(for: articlesWithAttachmentChanges.databaseObjects(), in: database)
			}
			if !articlesWithAuthorChanges.isEmpty {
				authorsLookupTable.saveRelatedObjects(for: articlesWithAuthorChanges.databaseObjects(), in: database)
			}
		}
	}

	func updateRelatedAttachments(_ parsedItems: [String: ParsedItem], _ articles: [String: Article]) {

		var articlesWithChanges = Set<Article>()

		for (articleID, parsedItem) in parsedItems {
			guard let article = articles[articleID] else {
				continue
			}
			if !parsedItemTagsMatchArticlesTag(parsedItem, article) {
				articlesChanges.insert(article)
			}
		}

		if articlesWithChanges.isEmpty {
			return
		}
		queue.update { (database) in
			tagsLookupTable.saveRelatedObjects(for: articlesWithChanges.databaseObjects(), in: database)
		}

	}

	func updateRelatedTags(_ parsedItems: [String: ParsedItem], _ articles: [String: Article]) {

		var articlesWithChanges = Set<Article>()

		for (articleID, parsedItem) in parsedItems {
			guard let article = articles[articleID] else {
				continue
			}
			if !parsedItemTagsMatchArticlesTag(parsedItem, article) {
				articlesChanges.insert(article)
			}
		}

		if articlesWithChanges.isEmpty {
			return
		}
		queue.update { (database) in
			tagsLookupTable.saveRelatedObjects(for: articlesWithChanges.databaseObjects(), in: database)
		}
	}

	func parsedItemTagsMatchArticlesTag(_ parsedItem: ParsedItem, _ article: Article) -> Bool {

		let parsedItemTags = parsedItem.tags
		let articleTags = article.tags

		if parsedItemTags == nil && articleTags == nil {
			return true
		}
		if parsedItemTags != nil && articleTags == nil {
			return false
		}
		if parsedItemTags == nil && articleTags != nil {
			return true
		}
		return Set(parsedItemTags!) == articleTags!
	}

	func saveNewParsedItems(_ parsedItems: [String: ParsedItem], _ feed: Feed) {

		// These parsedItems have no existing status or Article.

		queue.update { (database) in

			let articleIDs = Set(parsedItems.keys)
			self.statusesTable.ensureStatusesForArticleIDs(articleIDs, database)

			let articles = self.articlesWithParsedItems(Set(parsedItems.values), feed)
			self.saveUncachedNewArticles(articles, database)
		}
	}

	func articlesWithParsedItems(_ parsedItems: Set<ParsedItem>, _ feed: Feed) -> Set<Article> {

		// These Articles don’t get cached. Background-queue only.
		let feedID = feed.feedID
		return Set(parsedItems.flatMap{ articleWithParsedItem($0, feedID) })
	}

	func articleWithParsedItem(_ parsedItem: ParsedItem, _ feedID: String) -> Article? {

		guard let account = account else {
			assertionFailure("account is unexpectedly nil.")
			return nil
		}

		return Article(parsedItem: parsedItem, feedID: feedID, account: account)
	}

	func saveUncachedNewArticles(_ articles: Set<Article>, _ database: FMDatabase) {

		saveRelatedObjects(articles, database)

		let databaseDictionaries = articles.map { $0.databaseDictionary() }
		insertRows(databaseDictionaries, insertType: .orIgnore, in: database)
	}

	func saveRelatedObjects(_ articles: Set<Article>, _ database: FMDatabase) {

		let databaseObjects = articles.databaseObjects()

		authorsLookupTable.saveRelatedObjects(for: databaseObjects, in: database)
		attachmentsLookupTable.saveRelatedObjects(for: databaseObjects, in: database)
		tagsLookupTable.saveRelatedObjects(for: databaseObjects, in: database)
	}
	
	func statusIndicatesArticleIsIgnorable(_ status: ArticleStatus) -> Bool {

		// Ignorable articles: either userDeleted==1 or (not starred and arrival date > 4 months).

		if status.userDeleted {
			return true
		}
		if status.starred {
			return false
		}
		return status.dateArrived < maximumArticleCutoffDate
	}

	func filterParsedItems(_ parsedItems: [String: ParsedItem], _ statuses: [String: ArticleStatus]) -> [String: ParsedItem] {

		// Drop parsedItems that we can ignore.

		assert(Thread.isMainThread)

		var d = [String: ParsedItem]()

		for (articleID, parsedItem) in parsedItems {

			if let status = statuses[articleID] {
				if statusIndicatesArticleIsIgnorable(status) {
					continue
				}
			}
			d[articleID] = parsedItem
		}

		return d
	}

	func findNewParsedItems(_ parsedItems: [String: ParsedItem], _ statuses: [String: ArticleStatus], _ articles: [String: Article]) -> [String: ParsedItem] {

		// If there’s no existing status or Article, then it’s completely new.

		assert(Thread.isMainThread)

		var d = [String: ParsedItem]()

		for (articleID, parsedItem) in parsedItems {
			if statuses[articleID] == nil && articles[articleID] == nil {
				d[articleID] = parsedItem
			}
		}

		return d
	}

	func findExistingParsedItems(_ parsedItems: [String: ParsedItem], _ statuses: [String: ArticleStatus], _ articles: [String: Article]) -> [String: ParsedItem] {

		return [String: ParsedItem]() //TODO
	}
}

// MARK: -

private struct ArticleCache {
	
	// Main thread only — unlike the other object caches.
	// The cache contains a given article only until all outside references are gone.
	// Cache key is articleID.
	
	private let articlesMapTable: NSMapTable<NSString, Article> = NSMapTable.weakToWeakObjects()

	func uniquedArticles(_ articles: Set<Article>) -> Set<Article> {

		var articlesToReturn = Set<Article>()

		for article in articles {
			let articleID = article.articleID
			if let cachedArticle = cachedArticle(for: articleID) {
				articlesToReturn.insert(cachedArticle)
			}
			else {
				articlesToReturn.insert(article)
				addToCache(article)
			}
		}

		// At this point, every Article must have an attached Status.
		assert(articlesToReturn.eachHasAStatus())

		return articlesToReturn
	}
	
	private func cachedArticle(for articleID: String) -> Article? {
	
		return articlesMapTable.object(forKey: articleID as NSString)
	}
	
	private func addToCache(_ article: Article) {
	
		articlesMapTable.setObject(article, forKey: article.articleID as NSString)
	}
}




