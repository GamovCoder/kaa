/**
 *  Copyright 2014-2016 CyberVision, Inc.
 *
 *  Licensed under the Apache License, Version 2.0 (the "License");
 *  you may not use this file except in compliance with the License.
 *  You may obtain a copy of the License at
 *
 *       http://www.apache.org/licenses/LICENSE-2.0
 *
 *  Unless required by applicable law or agreed to in writing, software
 *  distributed under the License is distributed on an "AS IS" BASIS,
 *  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 *  See the License for the specific language governing permissions and
 *  limitations under the License.
 */

#import "DefaultBootstrapManager.h"
#import "GenericTransportInfo.h"
#import "NSMutableArray+Shuffling.h"
#import "TransportConnectionInfo.h"
#import "KaaLogging.h"
#import "KaaExceptions.h"

#define TAG @"DefaultBootstrapManager"
#define EXIT_FAILURE 1

@interface DefaultBootstrapManager ()

@property (nonatomic, strong) id<BootstrapTransport> transport;
@property (nonatomic, strong) id<ExecutorContext> context;
@property (nonatomic, strong) id<FailoverManager> failoverManager;
@property (nonatomic, strong) id<KaaInternalChannelManager> channelManager;

@property (nonatomic, strong) NSNumber *serverToApply;
@property (nonatomic, strong) NSArray *operationsServerList;                   //<ProtocolMetaData>
@property (nonatomic, strong) NSMutableDictionary *mappedOperationServerList;  //<TransportProtocolId, NSMutableArray<ProtocolMetaData>>
@property (nonatomic, strong) NSMutableDictionary *mappedIterators;            //<TransportProtocolId, NSEnumerator<ProtocolMetaData>>

- (NSMutableArray *)getTransportsByAccessPointId:(int)accessPointId;
- (void)notifyChannelManagerAboutServers:(NSMutableArray *)servers;
- (void)applyDecision:(FailoverDecision *)decision;

@end

@implementation DefaultBootstrapManager

- (instancetype)initWithTransport:(id<BootstrapTransport>)transport executorContext:(id<ExecutorContext>)context {
    self = [super init];
    if (self) {
        self.transport = transport;
        self.context = context;
        self.mappedOperationServerList = [NSMutableDictionary dictionary];
        self.mappedIterators = [NSMutableDictionary dictionary];
    }
    return self;
}

- (void)receiveOperationsServerList {
    DDLogDebug(@"%@ Going to invoke sync method of assigned transport", TAG);
    [self.transport sync];
}

- (void)useNextOperationsServerWithTransportId:(TransportProtocolId *)transportId {
    if (self.mappedOperationServerList && [self.mappedOperationServerList count] > 0) {
        ProtocolMetaData *nextOperServer = [self.mappedIterators[transportId] nextObject];
        if (nextOperServer) {
            DDLogDebug(@"%@ New server [%i] will be user for %@", TAG, nextOperServer.accessPointId, transportId);
            if (self.channelManager) {
                GenericTransportInfo *info = [[GenericTransportInfo alloc] initWithServerType:SERVER_OPERATIONS meta:nextOperServer];
                [self.channelManager onTransportConnectionInfoUpdated:info];
            } else {
                DDLogError(@"%@ Can not process server change. Channel manager was not specified", TAG);
            }
        } else {
            DDLogWarn(@"%@ Failed to find server for channel %@", TAG, transportId);
            FailoverDecision *decision = [self.failoverManager decisionOnFailoverStatus:FAILOVER_STATUS_OPERATION_SERVERS_NA];
            [self applyDecision:decision];
        }
    } else {
        [NSException raise:KaaBootstrapRuntimeException format:@"Operations Server list is empty"];
    }
}

- (void)setTransport:(id<BootstrapTransport>)transport {
    @synchronized (self) {
        _transport = transport;
    }
}

- (void)useNextOperationsServerByAccessPointId:(int32_t)accessPointId {
    @synchronized (self) {
        NSMutableArray *servers = [self getTransportsByAccessPointId:accessPointId];
        if (servers && [servers count] > 0) {
            [self notifyChannelManagerAboutServers:servers];
        } else {
            self.serverToApply = @(accessPointId);
            [self.transport sync];
        }
    }
}

- (void)setChannelManager:(id<KaaInternalChannelManager>)channelManager {
    @synchronized (self) {
        _channelManager = channelManager;
    }
}

- (void)setFailoverManager:(id<FailoverManager>)failoverManager {
    @synchronized (self) {
        _failoverManager = failoverManager;
    }
}

- (void)onProtocolListUpdated:(NSArray *)list {
    @synchronized (self) {
        DDLogVerbose(@"%@ Protocol list was updated", TAG);
        self.operationsServerList = list;
        [self.mappedOperationServerList removeAllObjects];
        [self.mappedIterators removeAllObjects];
        
        if (!self.operationsServerList || [self.operationsServerList count] == 0) {
            DDLogVerbose(@"%@ Received empty operations server list", TAG);
            FailoverDecision *decision = [self.failoverManager decisionOnFailoverStatus:FAILOVER_STATUS_NO_OPERATION_SERVERS_RECEIVED];
            [self applyDecision:decision];
            return;
        }
        
        for (ProtocolMetaData *server in self.operationsServerList) {
            TransportProtocolId *transportId =
            [[TransportProtocolId alloc] initWithId:server.protocolVersionInfo.id version:server.protocolVersionInfo.version];
            NSMutableArray *servers = self.mappedOperationServerList[transportId];
            if (!servers) {
                servers = [NSMutableArray array];
                self.mappedOperationServerList[transportId] = servers;
            }
            [servers addObject:server];
        }
        for (TransportProtocolId *key in self.mappedOperationServerList.allKeys) {
            NSMutableArray *servers = self.mappedOperationServerList[key];
            [servers shuffle];
            self.mappedIterators[key] = [servers objectEnumerator];
        }
        if (self.serverToApply) {
            NSMutableArray *servers = [self getTransportsByAccessPointId:[self.serverToApply intValue]];
            if (servers && [servers count] > 0) {
                [self notifyChannelManagerAboutServers:servers];
                self.serverToApply = nil;
            }
        } else {
            for (NSEnumerator *value in self.mappedIterators.allValues) {
                id<TransportConnectionInfo> info = [[GenericTransportInfo alloc] initWithServerType:SERVER_OPERATIONS meta:[value nextObject]];
                [self.channelManager onTransportConnectionInfoUpdated:info];
            }
        }
    }
}

- (void)notifyChannelManagerAboutServers:(NSMutableArray *)servers {
    for (ProtocolMetaData *meta in servers) {
        DDLogDebug(@"%@ Applying new transport %@", TAG, meta);
        GenericTransportInfo *info = [[GenericTransportInfo alloc] initWithServerType:SERVER_OPERATIONS meta:meta];
        [self.channelManager onTransportConnectionInfoUpdated:info];
    }
}

- (NSMutableArray *)getTransportsByAccessPointId:(int)accessPointId {
    if (!self.operationsServerList || [self.operationsServerList count] == 0) {
        [NSException raise:KaaBootstrapRuntimeException format:@"Operations Server list is empty"];
    }
    NSMutableArray *result = [NSMutableArray array];
    for (ProtocolMetaData *meta in self.operationsServerList) {
        if (meta.accessPointId == accessPointId) {
            [result addObject:meta];
        }
    }
    return result;
}

- (void)applyDecision:(FailoverDecision *)decision {
    switch (decision.failoverAction) {
        case FAILOVER_ACTION_NOOP:
        {
            DDLogWarn(@"%@ No operation is performed according to failover strategy decision", TAG);
        }
            break;
        case FAILOVER_ACTION_RETRY:
        {
            DDLogWarn(@"%@ Will try to receive operation servers in %lli ms as to failover strategy decision",
                      TAG, decision.retryPeriod);
            __weak typeof(self)weakSelf = self;
            dispatch_time_t delay = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(decision.retryPeriod * NSEC_PER_MSEC));
            dispatch_after(delay, [self.context getSheduledExecutor], ^{
                @try {
                    [weakSelf receiveOperationsServerList];
                }
                @catch (NSException *exception) {
                    DDLogWarn(@"%@ Excpetion caugh with name: %@, reason: %@", TAG, exception.name, exception.reason);
                    DDLogError(@"%@ Error while receiving operations server list", TAG);
                }
            });
        }
            break;
        case FAILOVER_ACTION_USE_NEXT_BOOTSTRAP:
        {
            DDLogWarn(@"%@ Trying to switch to the next bootstrap server as to failover strategy decision", TAG);
            [self.failoverManager onServerFailedWithConnectionInfo:[self.channelManager getActiveServerForType:TRANSPORT_TYPE_BOOTSTRAP]];
            __weak typeof(self)weakSelf = self;
            dispatch_time_t delay = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(decision.retryPeriod * NSEC_PER_MSEC));
            dispatch_after(delay, [self.context getSheduledExecutor], ^{
                @try {
                    [weakSelf receiveOperationsServerList];
                }
                @catch (NSException *exception) {
                    DDLogWarn(@"%@ Excpetion caugh with name: %@, reason: %@", TAG, exception.name, exception.reason);
                    DDLogError(@"%@ Error while receiving operations server list", TAG);
                }
            });
        }
            break;
        case FAILOVER_ACTION_STOP_APP:
        {
            DDLogWarn(@"%@ Stopping application as to failover strategy decision!", TAG);
            //TODO: Applications that use exit(..) are rejected by AppStore thus there should be found another way to exit
            exit(EXIT_FAILURE);
        }
            break;
        default:
            break;
    }
}

@end
