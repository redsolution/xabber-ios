//
//  RandomTitleManager.swift
//  xabber_test_xmpp
//
//
//
//
//  This program is free software; you can redistribute it and/or
//  modify it under the terms of the GNU General Public License as
//  published by the Free Software Foundation; either version 3 of the
//  License.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
//  General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//
//
//

import Foundation
import UIKit

class RandomTitleManager: NSObject {
    open class var shared: RandomTitleManager {
        struct RandomTitleManagerSingleton {
            static let instance = RandomTitleManager()
        }
        return RandomTitleManagerSingleton.instance
    }
    
    let titles = [
        "Ready to rock?",
        "Groovy!",
        "Be the change!",
        "Believe in yourself!",
        "Change is good!",
        "Carpe Diem!",
        "Focus and win!",
        "Spice must flow!",
        "Knowledge is power!",
        "Live your potential!",
        "Make it happen!",
        "Never give up!",
        "Success is yours!",
        "Yes you can!",
        "Happy trails!",
        "Stay vigilant!",
        "Keep it simple!",
        "Happiness is Choice!",
        "Friends are treasures!",
        "Citius, Altius, Fortius!",
        "Aim high!",
        "Be yourself!",
        "Dream big!",
        "There be dragons!",
        "Hello gorgeous!",
        "Infinite possibilities!",
        "Pretty awesome!",
        "Rise above!",
        "Woo hoo!",
        "Now or never!",
        "No strings attached!",
        "Time heals everything!",
        "Words can hurt!",
        "Try new things!",
        "Less is more!",
        "Trust your gut!",
        "You are beautiful!",
        "Straight into success!",
        "Get this done!",
        "Why not now?",
        "Got a dream?",
        "Keep going!",
        "They live! 😎 ",
        "Break the routine!",
        "Hello there!",
        "Passion never fails!",
        "More coffee please!",
        "Expect great things!",
        "Flex that smile)",
        "Remember to live!",
        "See the world!",
        "A fresh start!",
        "Real is rare!",
        "Dare to fail!",
        "Here & now!",
        "Just be happy!",
        "With ❤️ ",
        "Follow that dream!",
        "This is fine.",
        "It's ok, I still love you 💖 ",
        "Use your imagination!",
        "Because you can!",
        "Make it count!",
        "Oh what a day!",
        "Embrace the love!",
        "Attitude is everything!",
        "Float like a butterfly!",
        "Sting like a bee!",
        "Normal is boring!",
        "Life is good!",
        "Here's looking at you, kid!",
        "We'll always have Paris!",
        "Play it, Sam!",
        "You can't take the sky from me!",
        "TANSTAAFL",
        "Free as in freedom!",
        "Alwaуs have the high ground!",
        "Zed's dead, baby.",
        "It's an offer you can't refuse!",
        "Radiate positive vibes!",
        "Time is Now!",
        "Inconceivable!",
        "En Taro Adun, Executor!",
        "My life for Auir!",
        "I do this for Aiur!",
        "Kirov reporting!",
        "You're the one who knocks!",
        "It shall be done!",
        "This should be good!",
        "Go ahead, Commander!",
        "Sounds fun!",
        "Additional supply depots required!",
        "Not enough minerals!",
        "All crews reporting!",
        "Fasten your seatbelts!",
        "Transmit orders!",
        "Reporting for duty!",
        "Transmit coordinates!",
        "It'd be a pleasure!",
        "What is thy bidding, my master?",
        "We are the Borg!",
        "Prepare to be assimilated!",
        "It's only a flesh wound!",
        "Everything Changed When the Fire Nation Attacked!",
        "I used to be a user like you!",
        "The Boulder feels conflicted!",
        "Everything is connected!",
        "Follow the White Rabbit!",
        "Red or Blue pill?",
        "Wake up, Neo!",
        "Stannis is one true king!",
        "The sleeper must awaken!",
        "Fear is the mind-killer!",
        "Shaken, not stirred!",
        "We aim to please!",
        "Enjoy it while it lasts!",
        "Let off some steam!",
        "See you at the party!",
        "Game over, man! Game over!",
        "Frankly, my dear, I don't give a damn!",
        "Go ahead, make my day!",
        "May the Force be with you!",
        "You talkin' to me?",
        "Rosebud.",
        "E.T. phone home!",
        "Can you handle the truth?",
        "Tomorrow is another day!",
        "I'll be back!",
        "It's alive! It's alive!",
        "Well, nobody's perfect!",
        "Houston, we've had a problem!",
        "We've had a main B bus undervolt!",
        "You had me at 'hello!",
        "Here's Johnny!",
        "Soylent Green is people!",
        "Open the pod bay doors, HAL!",
        "I'm sorry, Dave, I'm afraid I can't do that!",
        "Who's on first?",
        "Nobody puts Baby in a corner!",
        "Do not talk about Fight Club!",
        "Why so serious?",
        "To infinity and beyond!",
        "Leave the gun. Take the cannoli!",
        "These go to eleven!",
        "It's dangerous to go alone. Take this!",
        "Cake is a lie!",
        "Our Princess is in another castle!",
        "Do a barrel roll!",
        "War. War never changes.",
        "Does this unit have a soul?",
        "Dany kind of forgot about the Iron Fleet!",
        "This is major Tom to ground control!",
        "We're gonna need a bigger boat!",
        "My precious!",
        "This is SPARTA!!!",
        "I’ll have what she’s having!",
        "We all go a little mad sometimes!",
        "Are you not entertained?",
        "See you, space cowboy...",
        "Recite your baseline.",
    ]
    
    public final func title() -> String {
        if UIDevice.isOldIPhonesFamily {
            return String(titles.filter({ $0.count < 18 }).randomElement()?
                .localizeString(id: "motivating_oneliner", arguments: [])
                .split(separator: "\n")
                .filter({ $0.count < 18 })
                .randomElement() ?? "Ready to rock?")
        } else {
            return String(titles.filter({ $0.count < 28 }).randomElement()?
                .localizeString(id: "motivating_oneliner", arguments: [])
                .split(separator: "\n")
                .filter({ $0.count < 28 })
                .randomElement() ?? "Ready to rock?")
        }
//        return titles.randomElement() ?? "Ready to rock?"
    }
}
