//
//  sqlitetest.swift
//  JaredUI
//
//  Created by Zeke Snider on 11/9/18.
//  Copyright © 2018 Zeke Snider. All rights reserved.
//

internal let SQLITE_STATIC = unsafeBitCast(0, to: sqlite3_destructor_type.self)
internal let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

import Cocoa
import JaredFramework
import Foundation
import SQLite3
import Contacts

class DatabaseHandler {
    var db: OpaquePointer?
    var querySinceID: String?
    var shouldExitThread = false
    var refreshSeconds = 5.0
    var authorizationError = false
    var statement: OpaquePointer? = nil
	var router: Router?
    
	init(router: Router) {
		self.router = router
		
        let databaseLocation = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Messages").appendingPathComponent("chat.db")
        
        if sqlite3_open(databaseLocation.path, &db) != SQLITE_OK {
            NSLog("Error opening SQLite database. Likely Full disk access error.")
            if let viewController = NSApplication.shared.keyWindow?.contentViewController as? ViewController {
                viewController.displayAccessError()
            }
            authorizationError = true
            return
        }
        
        querySinceID = getCurrentMaxRecordID()
    }
    
    deinit {
        shouldExitThread = true
        if sqlite3_close(db) != SQLITE_OK {
            print("error closing database")
        }
        
        db = nil
    }
    
    func start() {
        let dispatchQueue = DispatchQueue(label: "Jared Background Thread", qos: .background)
        dispatchQueue.async(execute: self.backgroundAction)
    }
    
    private func backgroundAction() {
        while shouldExitThread == false {
            let elapsed = queryNewRecords()
            Thread.sleep(forTimeInterval: refreshSeconds - elapsed)
        }
    }
    
    private func getCurrentMaxRecordID() -> String {
        let query = "SELECT MAX(rowID) FROM message"
        var id: String?
        var statement: OpaquePointer?
        
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) != SQLITE_OK {
            let errmsg = String(cString: sqlite3_errmsg(db)!)
            print("error preparing select: \(errmsg)")
        }
        
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idcString = sqlite3_column_text(statement, 0) else {
                break
            }
            
            id = String(cString: idcString)
        }
        
        if sqlite3_finalize(statement) != SQLITE_OK {
            let errmsg = String(cString: sqlite3_errmsg(db)!)
            print("error finalizing prepared statement: \(errmsg)")
        }
        
        return id ?? "10000000000000"
    }
    
    private func retrieveGroupInfo(chatID: String?) -> Group? {
        guard let handle = chatID else {
            return nil
        }
        
        let query = """
            SELECT handle.id
                FROM chat_handle_join INNER JOIN handle ON chat_handle_join.handle_id = handle.ROWID
                INNER JOIN chat ON chat_handle_join.chat_id = chat.ROWID
                WHERE chat_handle_join.chat_id = ?
        """
        
        var statement: OpaquePointer?
        
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) != SQLITE_OK {
            let errmsg = String(cString: sqlite3_errmsg(db)!)
            print("error preparing select: \(errmsg)")
        }
        
        if sqlite3_bind_text(statement, 1, chatID, -1, SQLITE_TRANSIENT) != SQLITE_OK {
            let errmsg = String(cString: sqlite3_errmsg(db)!)
            print("failure binding foo: \(errmsg)")
        }
        
        var People = [Person]()
        
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idcString = sqlite3_column_text(statement, 0) else {
                break
            }
            let handle = String(cString: idcString)
            let contact = ContactHelper.RetreiveContact(handle: handle)
            
            People.append(Person(givenName: contact?.givenName, handle: handle, isMe: false))
        }
        
        return Group(name: "", handle: handle, participants: People)
    }
    
	private func unwrapStringColumn(for sqlStatement: OpaquePointer?, at column: Int32) -> String? {
        if let cString = sqlite3_column_text(sqlStatement, column) {
            return String(cString: cString)
        } else {
            return nil
        }
    }
	
	private func retrieveAttachments(forMessage messageID: String) -> [Attachment] {
		let query = """
        SELECT ROWID,
        filename,
        mime_type,
        transfer_name,
        is_sticker
        FROM attachment
        INNER JOIN message_attachment_join
        ON attachment.ROWID = message_attachment_join.attachment_id
        WHERE message_id = ?
        """
		
		var attachmentStatement: OpaquePointer? = nil
		
		defer { attachmentStatement = nil }
			   
	   	if sqlite3_prepare_v2(db, query, -1, &attachmentStatement, nil) != SQLITE_OK {
		   let errmsg = String(cString: sqlite3_errmsg(db)!)
		   print("error preparing select: \(errmsg)")
	   	}
	   
		if sqlite3_bind_text(attachmentStatement, 1, messageID, -1, SQLITE_TRANSIENT) != SQLITE_OK {
		   let errmsg = String(cString: sqlite3_errmsg(db)!)
		   print("failure binding foo: \(errmsg)")
	   	}
		
		var attachments = [Attachment]()
		
		while sqlite3_step(attachmentStatement) == SQLITE_ROW {
			guard let rowID = unwrapStringColumn(for: attachmentStatement, at: 0) else { continue }
			guard let fileName = unwrapStringColumn(for: attachmentStatement, at: 1) else { continue }
			guard let mimeType = unwrapStringColumn(for: attachmentStatement, at: 2) else { continue }
			guard let transferName = unwrapStringColumn(for: attachmentStatement, at: 3) else { continue }
            let isSticker = sqlite3_column_int(attachmentStatement, 4) == 1
			
			attachments.append(Attachment(id: Int(rowID)!, filePath: fileName, mimeType: mimeType, fileName: transferName, isSticker: isSticker))
        }
        
        if sqlite3_finalize(attachmentStatement) != SQLITE_OK {
            let errmsg = String(cString: sqlite3_errmsg(db)!)
            print("error finalizing prepared statement: \(errmsg)")
        }
		
		return attachments
	}
    
    private func queryNewRecords() -> Double {
        let start = Date()
        
        let query = """
            SELECT handle.id, message.text, message.ROWID, message.cache_roomnames, message.is_from_me, message.destination_caller_id,
                message.date/1000000000 + strftime("%s", "2001-01-01"),
                message.cache_has_attachments,
                message.expressive_send_style_id
                FROM message INNER JOIN handle
                ON message.handle_id = handle.ROWID
                WHERE message.ROWID > ?
        """
        
        defer { statement = nil }
        
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) != SQLITE_OK {
            let errmsg = String(cString: sqlite3_errmsg(db)!)
            print("error preparing select: \(errmsg)")
        }
        
        if sqlite3_bind_text(statement, 1, querySinceID ?? "1000000000", -1, SQLITE_TRANSIENT) != SQLITE_OK {
            let errmsg = String(cString: sqlite3_errmsg(db)!)
            print("failure binding foo: \(errmsg)")
        }
        
        while sqlite3_step(statement) == SQLITE_ROW {
            let senderHandleOptional = unwrapStringColumn(for: statement, at: 0)
            let textOptional = unwrapStringColumn(for: statement, at: 1)
            let rowID = unwrapStringColumn(for: statement, at: 2)
            let roomName = unwrapStringColumn(for: statement, at: 3)
            let isFromMe = sqlite3_column_int(statement, 4) == 1
			let destinationOptional = unwrapStringColumn(for: statement, at: 5)
            let epochDate = TimeInterval(sqlite3_column_int64(statement, 6))
			let hasAttachment = sqlite3_column_int(statement, 7) == 1
			let sendStyle = unwrapStringColumn(for: statement, at: 8)
            
            querySinceID = rowID;
            
            guard let senderHandle = senderHandleOptional, let text = textOptional, let destination = destinationOptional else {
                break
            }
            
            let buddyName = ContactHelper.RetreiveContact(handle: senderHandle)?.givenName
            let myName = ContactHelper.RetreiveContact(handle: destination)?.givenName
			let sender: Person
			let recipient: RecipientEntity
			let group = retrieveGroupInfo(chatID: roomName)
			
			if (isFromMe) {
				sender = Person(givenName: myName, handle: destination, isMe: true)
				recipient = group ?? Person(givenName: buddyName, handle: senderHandle, isMe: false)
			} else {
				sender = Person(givenName: buddyName, handle: senderHandle, isMe: false)
				recipient = group ?? Person(givenName: myName, handle: destination, isMe: true)
			}
			
			let message = Message(body: TextBody(text), date: Date(timeIntervalSince1970: epochDate), sender: sender, recipient: recipient, attachments: hasAttachment ? retrieveAttachments(forMessage: rowID ?? "") : [],
								  sendStyle: sendStyle)
			
			router?.route(message: message)
        }
        
        if sqlite3_finalize(statement) != SQLITE_OK {
            let errmsg = String(cString: sqlite3_errmsg(db)!)
            print("error finalizing prepared statement: \(errmsg)")
        }
        
        return NSDate().timeIntervalSince(start)
    }
}

