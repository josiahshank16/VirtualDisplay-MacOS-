//
//  main.swift
//  VirtualDisplayCameraExtension
//
//  Created by Josiah Shank on 10/25/26.
//

import Foundation
import CoreMediaIO

let providerSource = VirtualDisplayCameraExtensionProviderSource(clientQueue: nil)
CMIOExtensionProvider.startService(provider: providerSource.provider)

CFRunLoopRun()
