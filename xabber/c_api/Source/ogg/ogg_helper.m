/**
 * Copyright IBM Corporation 2015
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 **/

#import "ogg_helper.h"
#import "ogg.h"

@interface OggHelper () {
    ogg_page oggPage;
    ogg_int64_t packetCount;
    ogg_int64_t granulePos;
    ogg_stream_state streamState;
}

@end

@implementation OggHelper

/**
 *  Initialize OggHelper instance
 *
 *  @return OggHelper instance
 */
- (OggHelper *) init{
    if (self = [super init]) {
        granulePos = 0;
        packetCount = 0;
        
        ogg_stream_init(&streamState, arc4random()%8888);
        
        return self;
    }
    return nil;
}

/**
 *  Write int - Little-endian
 *
 *  @param dest   Destination
 *  @param offset Offset
 *  @param value  Value
 */
void writeInt(unsigned char *dest, int offset, int value) {
    for(int i = 0;i < 4;i++) {
        dest[offset + i]=(unsigned char)(0xff & ((unsigned int)value)>>(i*8));
    }
}

/**
 *  Write short - Little-endian
 *
 *  @param dest   Destination
 *  @param offset Offset
 *  @param value  Value
 */
void writeShort(unsigned char *dest, int offset, int value) {
    for(int i = 0;i < 2;i++) {
        dest[offset + i]=(unsigned char)(0xff & ((unsigned int)value)>>(i*8));
    }
}

/**
 *  Write string - Little-endian
 *
 *  @param dest   Destination
 *  @param offset Offset
 *  @param value  Value
 *  @param length Length
 */
void writeString(unsigned char *dest, int offset, unsigned char *value, int length) {
    unsigned char *tempPointr = dest + offset;
    memcpy(tempPointr, value, length);
}

/**
 *  Write OggOpus packet
 *
 *  @param data                     Opus data
 *  @param isHeaderCommentPacket    is packet header comment packet?
 *
 *  @return NSMutableData instance or nil
 */
- (NSMutableData *) writeHeaderPacket: (NSData*) data comment: (BOOL) isHeaderCommentPacket {
    ogg_packet packet;
    packet.packet = (unsigned char *)[data bytes];
    packet.bytes = (long)[data length];
    packet.e_o_s = 0;
    packet.granulepos = granulePos;
    packet.packetno = packetCount++;
    packet.b_o_s = isHeaderCommentPacket ? 0 : 1;
    ogg_stream_packetin(&streamState, &packet);
    if (ogg_stream_flush(&streamState, &oggPage)) {
        NSMutableData *newData = [NSMutableData new];
        [newData appendBytes:oggPage.header length:oggPage.header_len];
        [newData appendBytes:oggPage.body length:oggPage.body_len];
        return newData;
    }
    return nil;
}

/**
 *  Write OggOpus packet
 *
 *  @param data      Opus data
 *  @param frameSize Frame size
 *  @param addEOS    add end-of-stream mark to page?
 *
 *  @return NSMutableData instance or nil
 */
- (NSMutableData *) writePacket: (NSData*) data frameSize:(int) frameSize end: (BOOL) addEOS {
    ogg_packet packet;
    packet.packet = (unsigned char *)[data bytes];
    packet.bytes = (long)([data length]);
    packet.b_o_s = 0;
    packet.e_o_s = addEOS ? 1 : 0;
    granulePos += frameSize;
    packet.granulepos = granulePos;
    packet.packetno = packetCount++;
    ogg_stream_packetin(&streamState, &packet);
    int isPageFlushed = 0;
    if (addEOS) {
        isPageFlushed = ogg_stream_flush(&streamState, &oggPage);
    } else {
        isPageFlushed = ogg_stream_pageout(&streamState, &oggPage);
    }
    if (isPageFlushed) {
        NSMutableData *newData = [NSMutableData new];
        [newData appendBytes:oggPage.header length:oggPage.header_len];
        [newData appendBytes:oggPage.body length:oggPage.body_len];
        return newData;
    }
    return nil;
}

@end
