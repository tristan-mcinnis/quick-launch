import Foundation

/// Emoji and symbols for the Emoji & Symbols catalog. The table is generated
/// from Unicode 16 names (`scripts/generate-emoji.py` documents the ranges)
/// with hand-written search words for the common ones. It is parsed once,
/// on the first request.
enum EmojiCatalog {
    static let items: [LauncherCatalogItem] = parse(table)

    /// Fitzpatrick skin tone modifiers, in the order the pickers show them.
    /// Index 0 means "leave the emoji as it is".
    static let skinToneModifiers: [Unicode.Scalar] = [
        "\u{1F3FB}", "\u{1F3FC}", "\u{1F3FD}", "\u{1F3FE}", "\u{1F3FF}",
    ]

    static let skinToneTitles = [
        "Default", "Light", "Medium Light", "Medium", "Medium Dark", "Dark",
    ]

    /// Applies a skin tone to the emoji that accept one. Everything else
    /// (symbols, flags, objects) is returned untouched, and an existing
    /// modifier is replaced rather than doubled.
    static func applyingSkinTone(_ tone: Int, to glyph: String) -> String {
        var scalars = Array(glyph.unicodeScalars)
        scalars.removeAll { $0.properties.isEmojiModifier }
        guard scalars.contains(where: { $0.properties.isEmojiModifierBase }) else { return glyph }
        guard tone >= 1, tone <= skinToneModifiers.count else {
            return String(String.UnicodeScalarView(scalars))
        }
        let modifier = skinToneModifiers[tone - 1]
        var result = String.UnicodeScalarView()
        for scalar in scalars {
            result.append(scalar)
            // The modifier follows its base directly, ahead of any joiner.
            if scalar.properties.isEmojiModifierBase { result.append(modifier) }
        }
        return String(result)
    }

    /// The catalog with the chosen skin tone applied. Item ids do not change,
    /// so pins and learned favourites survive a tone change.
    static func items(skinTone: Int) -> [LauncherCatalogItem] {
        guard skinTone > 0 else { return items }
        return items.map { item in
            var toned = item
            toned.value = applyingSkinTone(skinTone, to: item.value)
            return toned
        }
    }

    static func parse(_ table: String) -> [LauncherCatalogItem] {
        table.split(separator: "\n").compactMap { line in
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard columns.count == 4 else { return nil }
            let glyph = String(columns[0])
            let hex = glyph.unicodeScalars.map { String($0.value, radix: 16) }.joined(separator: "-")
            return LauncherCatalogItem(
                kind: .emoji,
                itemID: "emoji-\(hex)",
                title: String(columns[1]),
                detail: String(columns[2]),
                value: glyph,
                keywords: String(columns[3])
            )
        }
    }

    static let table = """
😀	Grinning Face	Smileys	grin smile happy
😁	Grinning Face with Smiling Eyes	Smileys	beaming grin
😂	Face with Tears of Joy	Smileys	joy lol laugh tears
😃	Smiling Face with Open Mouth	Smileys	
😄	Smiling Face with Open Mouth and Smiling Eyes	Smileys	
😅	Smiling Face with Open Mouth and Cold Sweat	Smileys	sweat smile phew
😆	Smiling Face with Open Mouth and Tightly Closed Eyes	Smileys	laughing squint
😇	Smiling Face with Halo	Smileys	
😈	Smiling Face with Horns	Smileys	
😉	Winking Face	Smileys	wink
😊	Smiling Face with Smiling Eyes	Smileys	smile happy blush
😋	Face Savouring Delicious Food	Smileys	
😌	Relieved Face	Smileys	
😍	Smiling Face with Heart Shaped Eyes	Smileys	heart eyes love
😎	Smiling Face with Sunglasses	Smileys	cool sunglasses
😏	Smirking Face	Smileys	
😐	Neutral Face	Smileys	neutral meh
😑	Expressionless Face	Smileys	
😒	Unamused Face	Smileys	
😓	Face with Cold Sweat	Smileys	
😔	Pensive Face	Smileys	
😕	Confused Face	Smileys	
😖	Confounded Face	Smileys	
😗	Kissing Face	Smileys	
😘	Face Throwing a Kiss	Smileys	kiss blow
😙	Kissing Face with Smiling Eyes	Smileys	
😚	Kissing Face with Closed Eyes	Smileys	
😛	Face with Stuck Out Tongue	Smileys	
😜	Face with Stuck Out Tongue and Winking Eye	Smileys	
😝	Face with Stuck Out Tongue and Tightly Closed Eyes	Smileys	
😞	Disappointed Face	Smileys	
😟	Worried Face	Smileys	
😠	Angry Face	Smileys	
😡	Pouting Face	Smileys	angry mad
😢	Crying Face	Smileys	
😣	Persevering Face	Smileys	
😤	Face with Look of Triumph	Smileys	
😥	Disappointed But Relieved Face	Smileys	
😦	Frowning Face with Open Mouth	Smileys	
😧	Anguished Face	Smileys	
😨	Fearful Face	Smileys	
😩	Weary Face	Smileys	
😪	Sleepy Face	Smileys	
😫	Tired Face	Smileys	
😬	Grimacing Face	Smileys	grimace awkward
😭	Loudly Crying Face	Smileys	cry sob
😮	Face with Open Mouth	Smileys	
😯	Hushed Face	Smileys	
😰	Face with Open Mouth and Cold Sweat	Smileys	
😱	Face Screaming in Fear	Smileys	scream shock
😲	Astonished Face	Smileys	
😳	Flushed Face	Smileys	
😴	Sleeping Face	Smileys	sleep zzz tired
😵	Dizzy Face	Smileys	
😶	Face Without Mouth	Smileys	
😷	Face with Medical Mask	Smileys	
😸	Grinning Cat Face with Smiling Eyes	Smileys	
😹	Cat Face with Tears of Joy	Smileys	
😺	Smiling Cat Face with Open Mouth	Smileys	
😻	Smiling Cat Face with Heart Shaped Eyes	Smileys	
😼	Cat Face with Wry Smile	Smileys	
😽	Kissing Cat Face with Closed Eyes	Smileys	
😾	Pouting Cat Face	Smileys	
😿	Crying Cat Face	Smileys	
🙀	Weary Cat Face	Smileys	
🙁	Slightly Frowning Face	Smileys	
🙂	Slightly Smiling Face	Smileys	slight smile
🙃	Upside Down Face	Smileys	
🙄	Face with Rolling Eyes	Smileys	eye roll
🙅	Face with No Good Gesture	Smileys	
🙆	Face with Ok Gesture	Smileys	
🙇	Person Bowing Deeply	Smileys	
🙈	See No Evil Monkey	Smileys	
🙉	Hear No Evil Monkey	Smileys	
🙊	Speak No Evil Monkey	Smileys	
🙋	Happy Person Raising One Hand	Smileys	
🙌	Person Raising Both Hands in Celebration	Smileys	raised hands hooray
🙍	Person Frowning	Smileys	
🙎	Person with Pouting Face	Smileys	
🙏	Person with Folded Hands	Smileys	pray thanks please folded hands
🌀	Cyclone	Objects & Nature	
🌁	Foggy	Objects & Nature	
🌂	Closed Umbrella	Objects & Nature	
🌃	Night with Stars	Objects & Nature	
🌄	Sunrise Over Mountains	Objects & Nature	
🌅	Sunrise	Objects & Nature	
🌆	Cityscape At Dusk	Objects & Nature	
🌇	Sunset Over Buildings	Objects & Nature	
🌈	Rainbow	Objects & Nature	rainbow
🌉	Bridge At Night	Objects & Nature	
🌊	Water Wave	Objects & Nature	
🌋	Volcano	Objects & Nature	
🌌	Milky Way	Objects & Nature	
🌍	Earth Globe Europe Africa	Objects & Nature	globe earth europe africa
🌎	Earth Globe Americas	Objects & Nature	
🌏	Earth Globe Asia Australia	Objects & Nature	globe asia australia
🌐	Globe with Meridians	Objects & Nature	
🌑	New Moon Symbol	Objects & Nature	
🌒	Waxing Crescent Moon Symbol	Objects & Nature	
🌓	First Quarter Moon Symbol	Objects & Nature	
🌔	Waxing Gibbous Moon Symbol	Objects & Nature	
🌕	Full Moon Symbol	Objects & Nature	
🌖	Waning Gibbous Moon Symbol	Objects & Nature	
🌗	Last Quarter Moon Symbol	Objects & Nature	
🌘	Waning Crescent Moon Symbol	Objects & Nature	
🌙	Crescent Moon	Objects & Nature	moon night
🌚	New Moon with Face	Objects & Nature	
🌛	First Quarter Moon with Face	Objects & Nature	
🌜	Last Quarter Moon with Face	Objects & Nature	
🌝	Full Moon with Face	Objects & Nature	
🌞	Sun with Face	Objects & Nature	
🌟	Glowing Star	Objects & Nature	glowing star
🌠	Shooting Star	Objects & Nature	
🌡	Thermometer	Objects & Nature	
🌢	Black Droplet	Objects & Nature	
🌣	White Sun	Objects & Nature	
🌤	White Sun with Small Cloud	Objects & Nature	
🌥	White Sun Behind Cloud	Objects & Nature	
🌦	White Sun Behind Cloud with Rain	Objects & Nature	
🌧	Cloud with Rain	Objects & Nature	rain
🌨	Cloud with Snow	Objects & Nature	
🌩	Cloud with Lightning	Objects & Nature	
🌪	Cloud with Tornado	Objects & Nature	
🌫	Fog	Objects & Nature	
🌬	Wind Blowing Face	Objects & Nature	
🌭	Hot Dog	Objects & Nature	
🌮	Taco	Objects & Nature	
🌯	Burrito	Objects & Nature	
🌰	Chestnut	Objects & Nature	
🌱	Seedling	Objects & Nature	
🌲	Evergreen Tree	Objects & Nature	
🌳	Deciduous Tree	Objects & Nature	
🌴	Palm Tree	Objects & Nature	
🌵	Cactus	Objects & Nature	
🌶	Hot Pepper	Objects & Nature	
🌷	Tulip	Objects & Nature	
🌸	Cherry Blossom	Objects & Nature	
🌹	Rose	Objects & Nature	
🌺	Hibiscus	Objects & Nature	
🌻	Sunflower	Objects & Nature	
🌼	Blossom	Objects & Nature	
🌽	Ear of Maize	Objects & Nature	
🌾	Ear of Rice	Objects & Nature	
🌿	Herb	Objects & Nature	
🍀	Four Leaf Clover	Objects & Nature	clover luck
🍁	Maple Leaf	Objects & Nature	
🍂	Fallen Leaf	Objects & Nature	
🍃	Leaf Fluttering in Wind	Objects & Nature	
🍄	Mushroom	Objects & Nature	
🍅	Tomato	Objects & Nature	
🍆	Aubergine	Objects & Nature	
🍇	Grapes	Objects & Nature	
🍈	Melon	Objects & Nature	
🍉	Watermelon	Objects & Nature	
🍊	Tangerine	Objects & Nature	
🍋	Lemon	Objects & Nature	
🍌	Banana	Objects & Nature	
🍍	Pineapple	Objects & Nature	
🍎	Red Apple	Objects & Nature	apple
🍏	Green Apple	Objects & Nature	
🍐	Pear	Objects & Nature	
🍑	Peach	Objects & Nature	
🍒	Cherries	Objects & Nature	
🍓	Strawberry	Objects & Nature	
🍔	Hamburger	Objects & Nature	burger
🍕	Slice of Pizza	Objects & Nature	pizza
🍖	Meat on Bone	Objects & Nature	
🍗	Poultry Leg	Objects & Nature	
🍘	Rice Cracker	Objects & Nature	
🍙	Rice Ball	Objects & Nature	
🍚	Cooked Rice	Objects & Nature	
🍛	Curry and Rice	Objects & Nature	
🍜	Steaming Bowl	Objects & Nature	
🍝	Spaghetti	Objects & Nature	
🍞	Bread	Objects & Nature	
🍟	French Fries	Objects & Nature	
🍠	Roasted Sweet Potato	Objects & Nature	
🍡	Dango	Objects & Nature	
🍢	Oden	Objects & Nature	
🍣	Sushi	Objects & Nature	
🍤	Fried Shrimp	Objects & Nature	
🍥	Fish Cake with Swirl Design	Objects & Nature	
🍦	Soft Ice Cream	Objects & Nature	
🍧	Shaved Ice	Objects & Nature	
🍨	Ice Cream	Objects & Nature	
🍩	Doughnut	Objects & Nature	
🍪	Cookie	Objects & Nature	
🍫	Chocolate Bar	Objects & Nature	
🍬	Candy	Objects & Nature	
🍭	Lollipop	Objects & Nature	
🍮	Custard	Objects & Nature	
🍯	Honey Pot	Objects & Nature	
🍰	Shortcake	Objects & Nature	
🍱	Bento Box	Objects & Nature	
🍲	Pot of Food	Objects & Nature	
🍳	Cooking	Objects & Nature	
🍴	Fork and Knife	Objects & Nature	
🍵	Teacup Without Handle	Objects & Nature	
🍶	Sake Bottle and Cup	Objects & Nature	
🍷	Wine Glass	Objects & Nature	wine
🍸	Cocktail Glass	Objects & Nature	
🍹	Tropical Drink	Objects & Nature	
🍺	Beer Mug	Objects & Nature	beer
🍻	Clinking Beer Mugs	Objects & Nature	
🍼	Baby Bottle	Objects & Nature	
🍽	Fork and Knife with Plate	Objects & Nature	
🍾	Bottle with Popping Cork	Objects & Nature	
🍿	Popcorn	Objects & Nature	
🎀	Ribbon	Objects & Nature	
🎁	Wrapped Present	Objects & Nature	gift present
🎂	Birthday Cake	Objects & Nature	
🎃	Jack O Lantern	Objects & Nature	
🎄	Christmas Tree	Objects & Nature	
🎅	Father Christmas	Objects & Nature	
🎆	Fireworks	Objects & Nature	
🎇	Firework Sparkler	Objects & Nature	
🎈	Balloon	Objects & Nature	
🎉	Party Popper	Objects & Nature	party tada celebrate
🎊	Confetti Ball	Objects & Nature	
🎋	Tanabata Tree	Objects & Nature	
🎌	Crossed Flags	Objects & Nature	
🎍	Pine Decoration	Objects & Nature	
🎎	Japanese Dolls	Objects & Nature	
🎏	Carp Streamer	Objects & Nature	
🎐	Wind Chime	Objects & Nature	
🎑	Moon Viewing Ceremony	Objects & Nature	
🎒	School Satchel	Objects & Nature	
🎓	Graduation Cap	Objects & Nature	
🎔	Heart with Tip on the Left	Objects & Nature	
🎕	Bouquet of Flowers	Objects & Nature	
🎖	Military Medal	Objects & Nature	
🎗	Reminder Ribbon	Objects & Nature	
🎘	Musical Keyboard with Jacks	Objects & Nature	
🎙	Studio Microphone	Objects & Nature	
🎚	Level Slider	Objects & Nature	
🎛	Control Knobs	Objects & Nature	
🎜	Beamed Ascending Musical Notes	Objects & Nature	
🎝	Beamed Descending Musical Notes	Objects & Nature	
🎞	Film Frames	Objects & Nature	
🎟	Admission Tickets	Objects & Nature	
🎠	Carousel Horse	Objects & Nature	
🎡	Ferris Wheel	Objects & Nature	
🎢	Roller Coaster	Objects & Nature	
🎣	Fishing Pole and Fish	Objects & Nature	
🎤	Microphone	Objects & Nature	
🎥	Movie Camera	Objects & Nature	
🎦	Cinema	Objects & Nature	
🎧	Headphone	Objects & Nature	headphones
🎨	Artist Palette	Objects & Nature	
🎩	Top Hat	Objects & Nature	
🎪	Circus Tent	Objects & Nature	
🎫	Ticket	Objects & Nature	
🎬	Clapper Board	Objects & Nature	
🎭	Performing Arts	Objects & Nature	
🎮	Video Game	Objects & Nature	
🎯	Direct Hit	Objects & Nature	target bullseye goal
🎰	Slot Machine	Objects & Nature	
🎱	Billiards	Objects & Nature	
🎲	Game Die	Objects & Nature	
🎳	Bowling	Objects & Nature	
🎴	Flower Playing Cards	Objects & Nature	
🎵	Musical Note	Objects & Nature	music note
🎶	Multiple Musical Notes	Objects & Nature	
🎷	Saxophone	Objects & Nature	
🎸	Guitar	Objects & Nature	
🎹	Musical Keyboard	Objects & Nature	
🎺	Trumpet	Objects & Nature	
🎻	Violin	Objects & Nature	
🎼	Musical Score	Objects & Nature	
🎽	Running Shirt with Sash	Objects & Nature	
🎾	Tennis Racquet and Ball	Objects & Nature	
🎿	Ski and Ski Boot	Objects & Nature	
🏀	Basketball and Hoop	Objects & Nature	
🏁	Chequered Flag	Objects & Nature	
🏂	Snowboarder	Objects & Nature	
🏃	Runner	Objects & Nature	
🏄	Surfer	Objects & Nature	
🏅	Sports Medal	Objects & Nature	
🏆	Trophy	Objects & Nature	trophy win
🏇	Horse Racing	Objects & Nature	
🏈	American Football	Objects & Nature	
🏉	Rugby Football	Objects & Nature	
🏊	Swimmer	Objects & Nature	
🏋	Weight Lifter	Objects & Nature	
🏌	Golfer	Objects & Nature	
🏍	Racing Motorcycle	Objects & Nature	
🏎	Racing Car	Objects & Nature	
🏏	Cricket Bat and Ball	Objects & Nature	
🏐	Volleyball	Objects & Nature	
🏑	Field Hockey Stick and Ball	Objects & Nature	
🏒	Ice Hockey Stick and Puck	Objects & Nature	
🏓	Table Tennis Paddle and Ball	Objects & Nature	
🏔	Snow Capped Mountain	Objects & Nature	
🏕	Camping	Objects & Nature	
🏖	Beach with Umbrella	Objects & Nature	
🏗	Building Construction	Objects & Nature	
🏘	House Buildings	Objects & Nature	
🏙	Cityscape	Objects & Nature	
🏚	Derelict House Building	Objects & Nature	
🏛	Classical Building	Objects & Nature	
🏜	Desert	Objects & Nature	
🏝	Desert Island	Objects & Nature	
🏞	National Park	Objects & Nature	
🏟	Stadium	Objects & Nature	
🏠	House Building	Objects & Nature	house home
🏡	House with Garden	Objects & Nature	
🏢	Office Building	Objects & Nature	office building
🏣	Japanese Post Office	Objects & Nature	
🏤	European Post Office	Objects & Nature	
🏥	Hospital	Objects & Nature	
🏦	Bank	Objects & Nature	
🏧	Automated Teller Machine	Objects & Nature	
🏨	Hotel	Objects & Nature	
🏩	Love Hotel	Objects & Nature	
🏪	Convenience Store	Objects & Nature	
🏫	School	Objects & Nature	
🏬	Department Store	Objects & Nature	
🏭	Factory	Objects & Nature	
🏮	Izakaya Lantern	Objects & Nature	
🏯	Japanese Castle	Objects & Nature	
🏰	European Castle	Objects & Nature	
🏱	White Pennant	Objects & Nature	
🏲	Black Pennant	Objects & Nature	
🏳	Waving White Flag	Objects & Nature	
🏴	Waving Black Flag	Objects & Nature	
🏵	Rosette	Objects & Nature	
🏶	Black Rosette	Objects & Nature	
🏷	Label	Objects & Nature	
🏸	Badminton Racquet and Shuttlecock	Objects & Nature	
🏹	Bow and Arrow	Objects & Nature	
🏺	Amphora	Objects & Nature	
🐀	Rat	Objects & Nature	
🐁	Mouse	Objects & Nature	
🐂	Ox	Objects & Nature	
🐃	Water Buffalo	Objects & Nature	
🐄	Cow	Objects & Nature	
🐅	Tiger	Objects & Nature	
🐆	Leopard	Objects & Nature	
🐇	Rabbit	Objects & Nature	
🐈	Cat	Objects & Nature	
🐉	Dragon	Objects & Nature	
🐊	Crocodile	Objects & Nature	
🐋	Whale	Objects & Nature	
🐌	Snail	Objects & Nature	
🐍	Snake	Objects & Nature	
🐎	Horse	Objects & Nature	
🐏	Ram	Objects & Nature	
🐐	Goat	Objects & Nature	
🐑	Sheep	Objects & Nature	
🐒	Monkey	Objects & Nature	
🐓	Rooster	Objects & Nature	
🐔	Chicken	Objects & Nature	
🐕	Dog	Objects & Nature	
🐖	Pig	Objects & Nature	
🐗	Boar	Objects & Nature	
🐘	Elephant	Objects & Nature	
🐙	Octopus	Objects & Nature	
🐚	Spiral Shell	Objects & Nature	
🐛	Bug	Objects & Nature	
🐜	Ant	Objects & Nature	
🐝	Honeybee	Objects & Nature	
🐞	Lady Beetle	Objects & Nature	
🐟	Fish	Objects & Nature	
🐠	Tropical Fish	Objects & Nature	
🐡	Blowfish	Objects & Nature	
🐢	Turtle	Objects & Nature	
🐣	Hatching Chick	Objects & Nature	
🐤	Baby Chick	Objects & Nature	
🐥	Front Facing Baby Chick	Objects & Nature	
🐦	Bird	Objects & Nature	
🐧	Penguin	Objects & Nature	
🐨	Koala	Objects & Nature	
🐩	Poodle	Objects & Nature	
🐪	Dromedary Camel	Objects & Nature	
🐫	Bactrian Camel	Objects & Nature	
🐬	Dolphin	Objects & Nature	
🐭	Mouse Face	Objects & Nature	
🐮	Cow Face	Objects & Nature	
🐯	Tiger Face	Objects & Nature	
🐰	Rabbit Face	Objects & Nature	
🐱	Cat Face	Objects & Nature	cat kitty
🐲	Dragon Face	Objects & Nature	
🐳	Spouting Whale	Objects & Nature	
🐴	Horse Face	Objects & Nature	
🐵	Monkey Face	Objects & Nature	
🐶	Dog Face	Objects & Nature	dog puppy
🐷	Pig Face	Objects & Nature	
🐸	Frog Face	Objects & Nature	
🐹	Hamster Face	Objects & Nature	
🐺	Wolf Face	Objects & Nature	
🐻	Bear Face	Objects & Nature	
🐼	Panda Face	Objects & Nature	
🐽	Pig Nose	Objects & Nature	
🐾	Paw Prints	Objects & Nature	
🐿	Chipmunk	Objects & Nature	
👀	Eyes	Objects & Nature	eyes look watching
👁	Eye	Objects & Nature	
👂	Ear	Objects & Nature	
👃	Nose	Objects & Nature	
👄	Mouth	Objects & Nature	
👅	Tongue	Objects & Nature	
👆	White Up Pointing Backhand Index	Objects & Nature	
👇	White Down Pointing Backhand Index	Objects & Nature	
👈	White Left Pointing Backhand Index	Objects & Nature	point left
👉	White Right Pointing Backhand Index	Objects & Nature	point right
👊	Fisted Hand Sign	Objects & Nature	
👋	Waving Hand Sign	Objects & Nature	wave hi hello bye
👌	Ok Hand Sign	Objects & Nature	
👍	Thumbs Up Sign	Objects & Nature	thumbs up like ok
👎	Thumbs Down Sign	Objects & Nature	thumbs down dislike
👏	Clapping Hands Sign	Objects & Nature	clap applause
👐	Open Hands Sign	Objects & Nature	
👑	Crown	Objects & Nature	
👒	Womans Hat	Objects & Nature	
👓	Eyeglasses	Objects & Nature	
👔	Necktie	Objects & Nature	
👕	T Shirt	Objects & Nature	
👖	Jeans	Objects & Nature	
👗	Dress	Objects & Nature	
👘	Kimono	Objects & Nature	
👙	Bikini	Objects & Nature	
👚	Womans Clothes	Objects & Nature	
👛	Purse	Objects & Nature	
👜	Handbag	Objects & Nature	
👝	Pouch	Objects & Nature	
👞	Mans Shoe	Objects & Nature	
👟	Athletic Shoe	Objects & Nature	
👠	High Heeled Shoe	Objects & Nature	
👡	Womans Sandal	Objects & Nature	
👢	Womans Boots	Objects & Nature	
👣	Footprints	Objects & Nature	
👤	Bust in Silhouette	Objects & Nature	
👥	Busts in Silhouette	Objects & Nature	
👦	Boy	Objects & Nature	
👧	Girl	Objects & Nature	
👨	Man	Objects & Nature	
👩	Woman	Objects & Nature	
👪	Family	Objects & Nature	
👫	Man and Woman Holding Hands	Objects & Nature	
👬	Two Men Holding Hands	Objects & Nature	
👭	Two Women Holding Hands	Objects & Nature	
👮	Police Officer	Objects & Nature	
👯	Woman with Bunny Ears	Objects & Nature	
👰	Bride with Veil	Objects & Nature	
👱	Person with Blond Hair	Objects & Nature	
👲	Man with Gua Pi Mao	Objects & Nature	
👳	Man with Turban	Objects & Nature	
👴	Older Man	Objects & Nature	
👵	Older Woman	Objects & Nature	
👶	Baby	Objects & Nature	
👷	Construction Worker	Objects & Nature	
👸	Princess	Objects & Nature	
👹	Japanese Ogre	Objects & Nature	
👺	Japanese Goblin	Objects & Nature	
👻	Ghost	Objects & Nature	
👼	Baby Angel	Objects & Nature	
👽	Extraterrestrial Alien	Objects & Nature	
👾	Alien Monster	Objects & Nature	
👿	Imp	Objects & Nature	
💀	Skull	Objects & Nature	
💁	Information Desk Person	Objects & Nature	
💂	Guardsman	Objects & Nature	
💃	Dancer	Objects & Nature	
💄	Lipstick	Objects & Nature	
💅	Nail Polish	Objects & Nature	
💆	Face Massage	Objects & Nature	
💇	Haircut	Objects & Nature	
💈	Barber Pole	Objects & Nature	
💉	Syringe	Objects & Nature	
💊	Pill	Objects & Nature	
💋	Kiss Mark	Objects & Nature	
💌	Love Letter	Objects & Nature	
💍	Ring	Objects & Nature	
💎	Gem Stone	Objects & Nature	
💏	Kiss	Objects & Nature	
💐	Bouquet	Objects & Nature	
💑	Couple with Heart	Objects & Nature	
💒	Wedding	Objects & Nature	
💓	Beating Heart	Objects & Nature	
💔	Broken Heart	Objects & Nature	broken heart
💕	Two Hearts	Objects & Nature	
💖	Sparkling Heart	Objects & Nature	
💗	Growing Heart	Objects & Nature	
💘	Heart with Arrow	Objects & Nature	
💙	Blue Heart	Objects & Nature	
💚	Green Heart	Objects & Nature	
💛	Yellow Heart	Objects & Nature	
💜	Purple Heart	Objects & Nature	
💝	Heart with Ribbon	Objects & Nature	
💞	Revolving Hearts	Objects & Nature	
💟	Heart Decoration	Objects & Nature	
💠	Diamond Shape with a Dot Inside	Objects & Nature	
💡	Electric Light Bulb	Objects & Nature	idea bulb light
💢	Anger Symbol	Objects & Nature	
💣	Bomb	Objects & Nature	
💤	Sleeping Symbol	Objects & Nature	zzz sleep
💥	Collision Symbol	Objects & Nature	boom collision
💦	Splashing Sweat Symbol	Objects & Nature	
💧	Droplet	Objects & Nature	
💨	Dash Symbol	Objects & Nature	
💩	Pile of Poo	Objects & Nature	
💪	Flexed Biceps	Objects & Nature	muscle strong flex
💫	Dizzy Symbol	Objects & Nature	
💬	Speech Balloon	Objects & Nature	speech bubble comment chat
💭	Thought Balloon	Objects & Nature	thought bubble
💮	White Flower	Objects & Nature	
💯	Hundred Points Symbol	Objects & Nature	100 percent perfect
💰	Money Bag	Objects & Nature	money bag
💱	Currency Exchange	Objects & Nature	
💲	Heavy Dollar Sign	Objects & Nature	
💳	Credit Card	Objects & Nature	
💴	Banknote with Yen Sign	Objects & Nature	
💵	Banknote with Dollar Sign	Objects & Nature	dollar banknote
💶	Banknote with Euro Sign	Objects & Nature	
💷	Banknote with Pound Sign	Objects & Nature	
💸	Money with Wings	Objects & Nature	
💹	Chart with Upwards Trend and Yen Sign	Objects & Nature	
💺	Seat	Objects & Nature	
💻	Personal Computer	Objects & Nature	laptop computer
💼	Briefcase	Objects & Nature	
💽	Minidisc	Objects & Nature	
💾	Floppy Disk	Objects & Nature	
💿	Optical Disc	Objects & Nature	
📀	Dvd	Objects & Nature	
📁	File Folder	Objects & Nature	
📂	Open File Folder	Objects & Nature	
📃	Page with Curl	Objects & Nature	
📄	Page Facing Up	Objects & Nature	
📅	Calendar	Objects & Nature	calendar date
📆	Tear Off Calendar	Objects & Nature	
📇	Card Index	Objects & Nature	
📈	Chart with Upwards Trend	Objects & Nature	chart up growth
📉	Chart with Downwards Trend	Objects & Nature	chart down
📊	Bar Chart	Objects & Nature	bar chart
📋	Clipboard	Objects & Nature	
📌	Pushpin	Objects & Nature	pin pushpin
📍	Round Pushpin	Objects & Nature	
📎	Paperclip	Objects & Nature	paperclip attach
📏	Straight Ruler	Objects & Nature	
📐	Triangular Ruler	Objects & Nature	
📑	Bookmark Tabs	Objects & Nature	
📒	Ledger	Objects & Nature	
📓	Notebook	Objects & Nature	
📔	Notebook with Decorative Cover	Objects & Nature	
📕	Closed Book	Objects & Nature	
📖	Open Book	Objects & Nature	
📗	Green Book	Objects & Nature	
📘	Blue Book	Objects & Nature	
📙	Orange Book	Objects & Nature	
📚	Books	Objects & Nature	
📛	Name Badge	Objects & Nature	
📜	Scroll	Objects & Nature	
📝	Memo	Objects & Nature	memo note
📞	Telephone Receiver	Objects & Nature	
📟	Pager	Objects & Nature	
📠	Fax Machine	Objects & Nature	
📡	Satellite Antenna	Objects & Nature	
📢	Public Address Loudspeaker	Objects & Nature	
📣	Cheering Megaphone	Objects & Nature	
📤	Outbox Tray	Objects & Nature	
📥	Inbox Tray	Objects & Nature	
📦	Package	Objects & Nature	package box
📧	E Mail Symbol	Objects & Nature	email mail
📨	Incoming Envelope	Objects & Nature	
📩	Envelope with Downwards Arrow Above	Objects & Nature	
📪	Closed Mailbox with Lowered Flag	Objects & Nature	
📫	Closed Mailbox with Raised Flag	Objects & Nature	
📬	Open Mailbox with Raised Flag	Objects & Nature	
📭	Open Mailbox with Lowered Flag	Objects & Nature	
📮	Postbox	Objects & Nature	
📯	Postal Horn	Objects & Nature	
📰	Newspaper	Objects & Nature	
📱	Mobile Phone	Objects & Nature	mobile phone
📲	Mobile Phone with Rightwards Arrow At Left	Objects & Nature	
📳	Vibration Mode	Objects & Nature	
📴	Mobile Phone Off	Objects & Nature	
📵	No Mobile Phones	Objects & Nature	
📶	Antenna with Bars	Objects & Nature	
📷	Camera	Objects & Nature	camera photo
📸	Camera with Flash	Objects & Nature	
📹	Video Camera	Objects & Nature	
📺	Television	Objects & Nature	
📻	Radio	Objects & Nature	
📼	Videocassette	Objects & Nature	
📽	Film Projector	Objects & Nature	
📾	Portable Stereo	Objects & Nature	
📿	Prayer Beads	Objects & Nature	
🔀	Twisted Rightwards Arrows	Objects & Nature	
🔁	Clockwise Rightwards and Leftwards Open Circle Arrows	Objects & Nature	
🔂	Clockwise Rightwards and Leftwards Open Circle Arrows with Circled One Overlay	Objects & Nature	
🔃	Clockwise Downwards and Upwards Open Circle Arrows	Objects & Nature	
🔄	Anticlockwise Downwards and Upwards Open Circle Arrows	Objects & Nature	
🔅	Low Brightness Symbol	Objects & Nature	
🔆	High Brightness Symbol	Objects & Nature	
🔇	Speaker with Cancellation Stroke	Objects & Nature	muted speaker
🔈	Speaker	Objects & Nature	
🔉	Speaker with One Sound Wave	Objects & Nature	
🔊	Speaker with Three Sound Waves	Objects & Nature	speaker loud
🔋	Battery	Objects & Nature	
🔌	Electric Plug	Objects & Nature	
🔍	Left Pointing Magnifying Glass	Objects & Nature	search magnifier find
🔎	Right Pointing Magnifying Glass	Objects & Nature	
🔏	Lock with Ink Pen	Objects & Nature	
🔐	Closed Lock with Key	Objects & Nature	
🔑	Key	Objects & Nature	
🔒	Lock	Objects & Nature	lock locked secure
🔓	Open Lock	Objects & Nature	unlock open
🔔	Bell	Objects & Nature	bell notification
🔕	Bell with Cancellation Stroke	Objects & Nature	bell off mute
🔖	Bookmark	Objects & Nature	
🔗	Link Symbol	Objects & Nature	link chain
🔘	Radio Button	Objects & Nature	
🔙	Back with Leftwards Arrow Above	Objects & Nature	
🔚	End with Leftwards Arrow Above	Objects & Nature	
🔛	On with Exclamation Mark with Left Right Arrow Above	Objects & Nature	
🔜	Soon with Rightwards Arrow Above	Objects & Nature	
🔝	Top with Upwards Arrow Above	Objects & Nature	
🔞	No One Under Eighteen Symbol	Objects & Nature	
🔟	Keycap Ten	Objects & Nature	
🔠	Input Symbol for Latin Capital Letters	Objects & Nature	
🔡	Input Symbol for Latin Small Letters	Objects & Nature	
🔢	Input Symbol for Numbers	Objects & Nature	
🔣	Input Symbol for Symbols	Objects & Nature	
🔤	Input Symbol for Latin Letters	Objects & Nature	
🔥	Fire	Objects & Nature	fire lit hot
🔦	Electric Torch	Objects & Nature	
🔧	Wrench	Objects & Nature	
🔨	Hammer	Objects & Nature	
🔩	Nut and Bolt	Objects & Nature	
🔪	Hocho	Objects & Nature	
🔫	Pistol	Objects & Nature	
🔬	Microscope	Objects & Nature	
🔭	Telescope	Objects & Nature	
🔮	Crystal Ball	Objects & Nature	
🔯	Six Pointed Star with Middle Dot	Objects & Nature	
🔰	Japanese Symbol for Beginner	Objects & Nature	
🔱	Trident Emblem	Objects & Nature	
🔲	Black Square Button	Objects & Nature	
🔳	White Square Button	Objects & Nature	
🔴	Large Red Circle	Objects & Nature	
🔵	Large Blue Circle	Objects & Nature	
🔶	Large Orange Diamond	Objects & Nature	
🔷	Large Blue Diamond	Objects & Nature	
🔸	Small Orange Diamond	Objects & Nature	
🔹	Small Blue Diamond	Objects & Nature	
🔺	Up Pointing Red Triangle	Objects & Nature	
🔻	Down Pointing Red Triangle	Objects & Nature	
🔼	Up Pointing Small Red Triangle	Objects & Nature	
🔽	Down Pointing Small Red Triangle	Objects & Nature	
🔾	Lower Right Shadowed White Circle	Objects & Nature	
🔿	Upper Right Shadowed White Circle	Objects & Nature	
🕀	Circled Cross Pommee	Objects & Nature	
🕁	Cross Pommee with Half Circle Below	Objects & Nature	
🕂	Cross Pommee	Objects & Nature	
🕃	Notched Left Semicircle with Three Dots	Objects & Nature	
🕄	Notched Right Semicircle with Three Dots	Objects & Nature	
🕅	Symbol for Marks Chapter	Objects & Nature	
🕆	White Latin Cross	Objects & Nature	
🕇	Heavy Latin Cross	Objects & Nature	
🕈	Celtic Cross	Objects & Nature	
🕉	Om Symbol	Objects & Nature	
🕊	Dove of Peace	Objects & Nature	
🕋	Kaaba	Objects & Nature	
🕌	Mosque	Objects & Nature	
🕍	Synagogue	Objects & Nature	
🕎	Menorah with Nine Branches	Objects & Nature	
🕏	Bowl of Hygieia	Objects & Nature	
🕐	Clock Face One Oclock	Objects & Nature	one oclock clock
🕑	Clock Face Two Oclock	Objects & Nature	
🕒	Clock Face Three Oclock	Objects & Nature	
🕓	Clock Face Four Oclock	Objects & Nature	
🕔	Clock Face Five Oclock	Objects & Nature	
🕕	Clock Face Six Oclock	Objects & Nature	
🕖	Clock Face Seven Oclock	Objects & Nature	
🕗	Clock Face Eight Oclock	Objects & Nature	
🕘	Clock Face Nine Oclock	Objects & Nature	
🕙	Clock Face Ten Oclock	Objects & Nature	
🕚	Clock Face Eleven Oclock	Objects & Nature	
🕛	Clock Face Twelve Oclock	Objects & Nature	
🕜	Clock Face One Thirty	Objects & Nature	
🕝	Clock Face Two Thirty	Objects & Nature	
🕞	Clock Face Three Thirty	Objects & Nature	
🕟	Clock Face Four Thirty	Objects & Nature	
🕠	Clock Face Five Thirty	Objects & Nature	
🕡	Clock Face Six Thirty	Objects & Nature	
🕢	Clock Face Seven Thirty	Objects & Nature	
🕣	Clock Face Eight Thirty	Objects & Nature	
🕤	Clock Face Nine Thirty	Objects & Nature	
🕥	Clock Face Ten Thirty	Objects & Nature	
🕦	Clock Face Eleven Thirty	Objects & Nature	
🕧	Clock Face Twelve Thirty	Objects & Nature	
🕨	Right Speaker	Objects & Nature	
🕩	Right Speaker with One Sound Wave	Objects & Nature	
🕪	Right Speaker with Three Sound Waves	Objects & Nature	
🕫	Bullhorn	Objects & Nature	
🕬	Bullhorn with Sound Waves	Objects & Nature	
🕭	Ringing Bell	Objects & Nature	
🕮	Book	Objects & Nature	
🕯	Candle	Objects & Nature	
🕰	Mantelpiece Clock	Objects & Nature	
🕱	Black Skull and Crossbones	Objects & Nature	
🕲	No Piracy	Objects & Nature	
🕳	Hole	Objects & Nature	
🕴	Man in Business Suit Levitating	Objects & Nature	
🕵	Sleuth Or Spy	Objects & Nature	
🕶	Dark Sunglasses	Objects & Nature	
🕷	Spider	Objects & Nature	
🕸	Spider Web	Objects & Nature	
🕹	Joystick	Objects & Nature	
🕺	Man Dancing	Objects & Nature	
🕻	Left Hand Telephone Receiver	Objects & Nature	
🕼	Telephone Receiver with Page	Objects & Nature	
🕽	Right Hand Telephone Receiver	Objects & Nature	
🕾	White Touchtone Telephone	Objects & Nature	
🕿	Black Touchtone Telephone	Objects & Nature	
🖀	Telephone on Top of Modem	Objects & Nature	
🖁	Clamshell Mobile Phone	Objects & Nature	
🖂	Back of Envelope	Objects & Nature	
🖃	Stamped Envelope	Objects & Nature	
🖄	Envelope with Lightning	Objects & Nature	
🖅	Flying Envelope	Objects & Nature	
🖆	Pen Over Stamped Envelope	Objects & Nature	
🖇	Linked Paperclips	Objects & Nature	
🖈	Black Pushpin	Objects & Nature	
🖉	Lower Left Pencil	Objects & Nature	
🖊	Lower Left Ballpoint Pen	Objects & Nature	
🖋	Lower Left Fountain Pen	Objects & Nature	
🖌	Lower Left Paintbrush	Objects & Nature	
🖍	Lower Left Crayon	Objects & Nature	
🖎	Left Writing Hand	Objects & Nature	
🖏	Turned Ok Hand Sign	Objects & Nature	
🖐	Raised Hand with Fingers Splayed	Objects & Nature	
🖑	Reversed Raised Hand with Fingers Splayed	Objects & Nature	
🖒	Reversed Thumbs Up Sign	Objects & Nature	
🖓	Reversed Thumbs Down Sign	Objects & Nature	
🖔	Reversed Victory Hand	Objects & Nature	
🖕	Reversed Hand with Middle Finger Extended	Objects & Nature	
🖖	Raised Hand with Part Between Middle and Ring Fingers	Objects & Nature	
🖗	White Down Pointing Left Hand Index	Objects & Nature	
🖘	Sideways White Left Pointing Index	Objects & Nature	
🖙	Sideways White Right Pointing Index	Objects & Nature	
🖚	Sideways Black Left Pointing Index	Objects & Nature	
🖛	Sideways Black Right Pointing Index	Objects & Nature	
🖜	Black Left Pointing Backhand Index	Objects & Nature	
🖝	Black Right Pointing Backhand Index	Objects & Nature	
🖞	Sideways White Up Pointing Index	Objects & Nature	
🖟	Sideways White Down Pointing Index	Objects & Nature	
🖠	Sideways Black Up Pointing Index	Objects & Nature	
🖡	Sideways Black Down Pointing Index	Objects & Nature	
🖢	Black Up Pointing Backhand Index	Objects & Nature	
🖣	Black Down Pointing Backhand Index	Objects & Nature	
🖤	Black Heart	Objects & Nature	
🖥	Desktop Computer	Objects & Nature	desktop computer
🖦	Keyboard and Mouse	Objects & Nature	
🖧	Three Networked Computers	Objects & Nature	
🖨	Printer	Objects & Nature	
🖩	Pocket Calculator	Objects & Nature	
🖪	Black Hard Shell Floppy Disk	Objects & Nature	
🖫	White Hard Shell Floppy Disk	Objects & Nature	
🖬	Soft Shell Floppy Disk	Objects & Nature	
🖭	Tape Cartridge	Objects & Nature	
🖮	Wired Keyboard	Objects & Nature	
🖯	One Button Mouse	Objects & Nature	
🖰	Two Button Mouse	Objects & Nature	
🖱	Three Button Mouse	Objects & Nature	mouse computer
🖲	Trackball	Objects & Nature	
🖳	Old Personal Computer	Objects & Nature	
🖴	Hard Disk	Objects & Nature	
🖵	Screen	Objects & Nature	
🖶	Printer Icon	Objects & Nature	
🖷	Fax Icon	Objects & Nature	
🖸	Optical Disc Icon	Objects & Nature	
🖹	Document with Text	Objects & Nature	
🖺	Document with Text and Picture	Objects & Nature	
🖻	Document with Picture	Objects & Nature	
🖼	Frame with Picture	Objects & Nature	
🖽	Frame with Tiles	Objects & Nature	
🖾	Frame with An X	Objects & Nature	
🖿	Black Folder	Objects & Nature	
🗀	Folder	Objects & Nature	
🗁	Open Folder	Objects & Nature	
🗂	Card Index Dividers	Objects & Nature	
🗃	Card File Box	Objects & Nature	
🗄	File Cabinet	Objects & Nature	
🗅	Empty Note	Objects & Nature	
🗆	Empty Note Page	Objects & Nature	
🗇	Empty Note Pad	Objects & Nature	
🗈	Note	Objects & Nature	
🗉	Note Page	Objects & Nature	
🗊	Note Pad	Objects & Nature	
🗋	Empty Document	Objects & Nature	
🗌	Empty Page	Objects & Nature	
🗍	Empty Pages	Objects & Nature	
🗎	Document	Objects & Nature	
🗏	Page	Objects & Nature	
🗐	Pages	Objects & Nature	
🗑	Wastebasket	Objects & Nature	trash delete bin
🗒	Spiral Note Pad	Objects & Nature	
🗓	Spiral Calendar Pad	Objects & Nature	calendar spiral
🗔	Desktop Window	Objects & Nature	
🗕	Minimize	Objects & Nature	
🗖	Maximize	Objects & Nature	
🗗	Overlap	Objects & Nature	
🗘	Clockwise Right and Left Semicircle Arrows	Objects & Nature	
🗙	Cancellation X	Objects & Nature	
🗚	Increase Font Size Symbol	Objects & Nature	
🗛	Decrease Font Size Symbol	Objects & Nature	
🗜	Compression	Objects & Nature	
🗝	Old Key	Objects & Nature	
🗞	Rolled Up Newspaper	Objects & Nature	
🗟	Page with Circled Text	Objects & Nature	
🗠	Stock Chart	Objects & Nature	
🗡	Dagger Knife	Objects & Nature	
🗢	Lips	Objects & Nature	
🗣	Speaking Head in Silhouette	Objects & Nature	
🗤	Three Rays Above	Objects & Nature	
🗥	Three Rays Below	Objects & Nature	
🗦	Three Rays Left	Objects & Nature	
🗧	Three Rays Right	Objects & Nature	
🗨	Left Speech Bubble	Objects & Nature	
🗩	Right Speech Bubble	Objects & Nature	
🗪	Two Speech Bubbles	Objects & Nature	
🗫	Three Speech Bubbles	Objects & Nature	
🗬	Left Thought Bubble	Objects & Nature	
🗭	Right Thought Bubble	Objects & Nature	
🗮	Left Anger Bubble	Objects & Nature	
🗯	Right Anger Bubble	Objects & Nature	
🗰	Mood Bubble	Objects & Nature	
🗱	Lightning Mood Bubble	Objects & Nature	
🗲	Lightning Mood	Objects & Nature	
🗳	Ballot Box with Ballot	Objects & Nature	
🗴	Ballot Script X	Objects & Nature	
🗵	Ballot Box with Script X	Objects & Nature	
🗶	Ballot Bold Script X	Objects & Nature	
🗷	Ballot Box with Bold Script X	Objects & Nature	
🗸	Light Check Mark	Objects & Nature	
🗹	Ballot Box with Bold Check	Objects & Nature	
🗺	World Map	Objects & Nature	
🗻	Mount Fuji	Objects & Nature	
🗼	Tokyo Tower	Objects & Nature	
🗽	Statue of Liberty	Objects & Nature	
🗾	Silhouette of Japan	Objects & Nature	
🗿	Moyai	Objects & Nature	
🚀	Rocket	Travel	rocket launch ship
🚁	Helicopter	Travel	
🚂	Steam Locomotive	Travel	
🚃	Railway Car	Travel	
🚄	High Speed Train	Travel	
🚅	High Speed Train with Bullet Nose	Travel	
🚆	Train	Travel	
🚇	Metro	Travel	
🚈	Light Rail	Travel	
🚉	Station	Travel	
🚊	Tram	Travel	
🚋	Tram Car	Travel	
🚌	Bus	Travel	
🚍	Oncoming Bus	Travel	
🚎	Trolleybus	Travel	
🚏	Bus Stop	Travel	
🚐	Minibus	Travel	
🚑	Ambulance	Travel	
🚒	Fire Engine	Travel	
🚓	Police Car	Travel	
🚔	Oncoming Police Car	Travel	
🚕	Taxi	Travel	
🚖	Oncoming Taxi	Travel	
🚗	Automobile	Travel	car
🚘	Oncoming Automobile	Travel	
🚙	Recreational Vehicle	Travel	
🚚	Delivery Truck	Travel	
🚛	Articulated Lorry	Travel	
🚜	Tractor	Travel	
🚝	Monorail	Travel	
🚞	Mountain Railway	Travel	
🚟	Suspension Railway	Travel	
🚠	Mountain Cableway	Travel	
🚡	Aerial Tramway	Travel	
🚢	Ship	Travel	
🚣	Rowboat	Travel	
🚤	Speedboat	Travel	
🚥	Horizontal Traffic Light	Travel	
🚦	Vertical Traffic Light	Travel	
🚧	Construction Sign	Travel	
🚨	Police Cars Revolving Light	Travel	
🚩	Triangular Flag on Post	Travel	
🚪	Door	Travel	
🚫	No Entry Sign	Travel	
🚬	Smoking Symbol	Travel	
🚭	No Smoking Symbol	Travel	
🚮	Put Litter in Its Place Symbol	Travel	
🚯	Do Not Litter Symbol	Travel	
🚰	Potable Water Symbol	Travel	
🚱	Non Potable Water Symbol	Travel	
🚲	Bicycle	Travel	
🚳	No Bicycles	Travel	
🚴	Bicyclist	Travel	
🚵	Mountain Bicyclist	Travel	
🚶	Pedestrian	Travel	
🚷	No Pedestrians	Travel	
🚸	Children Crossing	Travel	
🚹	Mens Symbol	Travel	
🚺	Womens Symbol	Travel	
🚻	Restroom	Travel	
🚼	Baby Symbol	Travel	
🚽	Toilet	Travel	
🚾	Water Closet	Travel	
🚿	Shower	Travel	
🛀	Bath	Travel	
🛁	Bathtub	Travel	
🛂	Passport Control	Travel	
🛃	Customs	Travel	
🛄	Baggage Claim	Travel	
🛅	Left Luggage	Travel	
🛆	Triangle with Rounded Corners	Travel	
🛇	Prohibited Sign	Travel	
🛈	Circled Information Source	Travel	
🛉	Boys Symbol	Travel	
🛊	Girls Symbol	Travel	
🛋	Couch and Lamp	Travel	
🛌	Sleeping Accommodation	Travel	
🛍	Shopping Bags	Travel	
🛎	Bellhop Bell	Travel	
🛏	Bed	Travel	
🛐	Place of Worship	Travel	
🛑	Octagonal Sign	Travel	
🛒	Shopping Trolley	Travel	
🛓	Stupa	Travel	
🛔	Pagoda	Travel	
🛕	Hindu Temple	Travel	
🛖	Hut	Travel	
🛗	Elevator	Travel	
🛜	Wireless	Travel	
🛝	Playground Slide	Travel	
🛞	Wheel	Travel	
🛟	Ring Buoy	Travel	
🛠	Hammer and Wrench	Travel	
🛡	Shield	Travel	
🛢	Oil Drum	Travel	
🛣	Motorway	Travel	
🛤	Railway Track	Travel	
🛥	Motor Boat	Travel	
🛦	Up Pointing Military Airplane	Travel	
🛧	Up Pointing Airplane	Travel	
🛨	Up Pointing Small Airplane	Travel	
🛩	Small Airplane	Travel	
🛪	Northeast Pointing Airplane	Travel	
🛫	Airplane Departure	Travel	
🛬	Airplane Arriving	Travel	
🛰	Satellite	Travel	
🛱	Oncoming Fire Engine	Travel	
🛲	Diesel Locomotive	Travel	
🛳	Passenger Ship	Travel	
🛴	Scooter	Travel	
🛵	Motor Scooter	Travel	
🛶	Canoe	Travel	
🛷	Sled	Travel	
🛸	Flying Saucer	Travel	
🛹	Skateboard	Travel	
🛺	Auto Rickshaw	Travel	
🛻	Pickup Truck	Travel	
🛼	Roller Skate	Travel	
🤀	Circled Cross Formee with Four Dots	People & Things	
🤁	Circled Cross Formee with Two Dots	People & Things	
🤂	Circled Cross Formee	People & Things	
🤃	Left Half Circle with Four Dots	People & Things	
🤄	Left Half Circle with Three Dots	People & Things	
🤅	Left Half Circle with Two Dots	People & Things	
🤆	Left Half Circle with Dot	People & Things	
🤇	Left Half Circle	People & Things	
🤈	Downward Facing Hook	People & Things	
🤉	Downward Facing Notched Hook	People & Things	
🤊	Downward Facing Hook with Dot	People & Things	
🤋	Downward Facing Notched Hook with Dot	People & Things	
🤌	Pinched Fingers	People & Things	
🤍	White Heart	People & Things	
🤎	Brown Heart	People & Things	
🤏	Pinching Hand	People & Things	
🤐	Zipper Mouth Face	People & Things	
🤑	Money Mouth Face	People & Things	
🤒	Face with Thermometer	People & Things	
🤓	Nerd Face	People & Things	
🤔	Thinking Face	People & Things	thinking hmm
🤕	Face with Head Bandage	People & Things	
🤖	Robot Face	People & Things	
🤗	Hugging Face	People & Things	hug
🤘	Sign of the Horns	People & Things	
🤙	Call Me Hand	People & Things	
🤚	Raised Back of Hand	People & Things	
🤛	Left Facing Fist	People & Things	
🤜	Right Facing Fist	People & Things	
🤝	Handshake	People & Things	handshake deal agree
🤞	Hand with Index and Middle Fingers Crossed	People & Things	fingers crossed luck
🤟	I Love You Hand Sign	People & Things	
🤠	Face with Cowboy Hat	People & Things	
🤡	Clown Face	People & Things	
🤢	Nauseated Face	People & Things	
🤣	Rolling on the Floor Laughing	People & Things	rofl rolling laughing
🤤	Drooling Face	People & Things	
🤥	Lying Face	People & Things	
🤦	Face Palm	People & Things	
🤧	Sneezing Face	People & Things	
🤨	Face with One Eyebrow Raised	People & Things	
🤩	Grinning Face with Star Eyes	People & Things	star struck wow
🤪	Grinning Face with One Large and One Small Eye	People & Things	
🤫	Face with Finger Covering Closed Lips	People & Things	
🤬	Serious Face with Symbols Covering Mouth	People & Things	
🤭	Smiling Face with Smiling Eyes and Hand Covering Mouth	People & Things	
🤮	Face with Open Mouth Vomiting	People & Things	
🤯	Shocked Face with Exploding Head	People & Things	mind blown exploding
🤰	Pregnant Woman	People & Things	
🤱	Breast Feeding	People & Things	
🤲	Palms Up Together	People & Things	
🤳	Selfie	People & Things	
🤴	Prince	People & Things	
🤵	Man in Tuxedo	People & Things	
🤶	Mother Christmas	People & Things	
🤷	Shrug	People & Things	
🤸	Person Doing Cartwheel	People & Things	
🤹	Juggling	People & Things	
🤺	Fencer	People & Things	
🤻	Modern Pentathlon	People & Things	
🤼	Wrestlers	People & Things	
🤽	Water Polo	People & Things	
🤾	Handball	People & Things	
🤿	Diving Mask	People & Things	
🥀	Wilted Flower	People & Things	
🥁	Drum with Drumsticks	People & Things	
🥂	Clinking Glasses	People & Things	clink glasses cheers
🥃	Tumbler Glass	People & Things	
🥄	Spoon	People & Things	
🥅	Goal Net	People & Things	
🥆	Rifle	People & Things	
🥇	First Place Medal	People & Things	
🥈	Second Place Medal	People & Things	
🥉	Third Place Medal	People & Things	
🥊	Boxing Glove	People & Things	
🥋	Martial Arts Uniform	People & Things	
🥌	Curling Stone	People & Things	
🥍	Lacrosse Stick and Ball	People & Things	
🥎	Softball	People & Things	
🥏	Flying Disc	People & Things	
🥐	Croissant	People & Things	
🥑	Avocado	People & Things	
🥒	Cucumber	People & Things	
🥓	Bacon	People & Things	
🥔	Potato	People & Things	
🥕	Carrot	People & Things	
🥖	Baguette Bread	People & Things	
🥗	Green Salad	People & Things	
🥘	Shallow Pan of Food	People & Things	
🥙	Stuffed Flatbread	People & Things	
🥚	Egg	People & Things	
🥛	Glass of Milk	People & Things	
🥜	Peanuts	People & Things	
🥝	Kiwifruit	People & Things	
🥞	Pancakes	People & Things	
🥟	Dumpling	People & Things	
🥠	Fortune Cookie	People & Things	
🥡	Takeout Box	People & Things	
🥢	Chopsticks	People & Things	
🥣	Bowl with Spoon	People & Things	
🥤	Cup with Straw	People & Things	
🥥	Coconut	People & Things	
🥦	Broccoli	People & Things	
🥧	Pie	People & Things	
🥨	Pretzel	People & Things	
🥩	Cut of Meat	People & Things	
🥪	Sandwich	People & Things	
🥫	Canned Food	People & Things	
🥬	Leafy Green	People & Things	
🥭	Mango	People & Things	
🥮	Moon Cake	People & Things	
🥯	Bagel	People & Things	
🥰	Smiling Face with Smiling Eyes and Three Hearts	People & Things	smiling hearts love
🥱	Yawning Face	People & Things	
🥲	Smiling Face with Tear	People & Things	
🥳	Face with Party Horn and Party Hat	People & Things	party face celebrate
🥴	Face with Uneven Eyes and Wavy Mouth	People & Things	
🥵	Overheated Face	People & Things	
🥶	Freezing Face	People & Things	
🥷	Ninja	People & Things	
🥸	Disguised Face	People & Things	
🥹	Face Holding Back Tears	People & Things	
🥺	Face with Pleading Eyes	People & Things	pleading puppy eyes
🥻	Sari	People & Things	
🥼	Lab Coat	People & Things	
🥽	Goggles	People & Things	
🥾	Hiking Boot	People & Things	
🥿	Flat Shoe	People & Things	
🦀	Crab	People & Things	
🦁	Lion Face	People & Things	
🦂	Scorpion	People & Things	
🦃	Turkey	People & Things	
🦄	Unicorn Face	People & Things	
🦅	Eagle	People & Things	
🦆	Duck	People & Things	
🦇	Bat	People & Things	
🦈	Shark	People & Things	
🦉	Owl	People & Things	
🦊	Fox Face	People & Things	
🦋	Butterfly	People & Things	
🦌	Deer	People & Things	
🦍	Gorilla	People & Things	
🦎	Lizard	People & Things	
🦏	Rhinoceros	People & Things	
🦐	Shrimp	People & Things	
🦑	Squid	People & Things	
🦒	Giraffe Face	People & Things	
🦓	Zebra Face	People & Things	
🦔	Hedgehog	People & Things	
🦕	Sauropod	People & Things	
🦖	T Rex	People & Things	
🦗	Cricket	People & Things	
🦘	Kangaroo	People & Things	
🦙	Llama	People & Things	
🦚	Peacock	People & Things	
🦛	Hippopotamus	People & Things	
🦜	Parrot	People & Things	
🦝	Raccoon	People & Things	
🦞	Lobster	People & Things	
🦟	Mosquito	People & Things	
🦠	Microbe	People & Things	
🦡	Badger	People & Things	
🦢	Swan	People & Things	
🦣	Mammoth	People & Things	
🦤	Dodo	People & Things	
🦥	Sloth	People & Things	
🦦	Otter	People & Things	
🦧	Orangutan	People & Things	
🦨	Skunk	People & Things	
🦩	Flamingo	People & Things	
🦪	Oyster	People & Things	
🦫	Beaver	People & Things	
🦬	Bison	People & Things	
🦭	Seal	People & Things	
🦮	Guide Dog	People & Things	
🦯	Probing Cane	People & Things	
🦴	Bone	People & Things	
🦵	Leg	People & Things	
🦶	Foot	People & Things	
🦷	Tooth	People & Things	
🦸	Superhero	People & Things	
🦹	Supervillain	People & Things	
🦺	Safety Vest	People & Things	
🦻	Ear with Hearing Aid	People & Things	
🦼	Motorized Wheelchair	People & Things	
🦽	Manual Wheelchair	People & Things	
🦾	Mechanical Arm	People & Things	
🦿	Mechanical Leg	People & Things	
🧀	Cheese Wedge	People & Things	
🧁	Cupcake	People & Things	
🧂	Salt Shaker	People & Things	
🧃	Beverage Box	People & Things	
🧄	Garlic	People & Things	
🧅	Onion	People & Things	
🧆	Falafel	People & Things	
🧇	Waffle	People & Things	
🧈	Butter	People & Things	
🧉	Mate Drink	People & Things	
🧊	Ice Cube	People & Things	
🧋	Bubble Tea	People & Things	
🧌	Troll	People & Things	
🧍	Standing Person	People & Things	
🧎	Kneeling Person	People & Things	
🧏	Deaf Person	People & Things	
🧐	Face with Monocle	People & Things	
🧑	Adult	People & Things	
🧒	Child	People & Things	
🧓	Older Adult	People & Things	
🧔	Bearded Person	People & Things	
🧕	Person with Headscarf	People & Things	
🧖	Person in Steamy Room	People & Things	
🧗	Person Climbing	People & Things	
🧘	Person in Lotus Position	People & Things	
🧙	Mage	People & Things	
🧚	Fairy	People & Things	
🧛	Vampire	People & Things	
🧜	Merperson	People & Things	
🧝	Elf	People & Things	
🧞	Genie	People & Things	
🧟	Zombie	People & Things	
🧠	Brain	People & Things	brain
🧡	Orange Heart	People & Things	
🧢	Billed Cap	People & Things	
🧣	Scarf	People & Things	
🧤	Gloves	People & Things	
🧥	Coat	People & Things	
🧦	Socks	People & Things	
🧧	Red Gift Envelope	People & Things	
🧨	Firecracker	People & Things	
🧩	Jigsaw Puzzle Piece	People & Things	
🧪	Test Tube	People & Things	
🧫	Petri Dish	People & Things	
🧬	Dna Double Helix	People & Things	
🧭	Compass	People & Things	
🧮	Abacus	People & Things	
🧯	Fire Extinguisher	People & Things	
🧰	Toolbox	People & Things	
🧱	Brick	People & Things	
🧲	Magnet	People & Things	
🧳	Luggage	People & Things	
🧴	Lotion Bottle	People & Things	
🧵	Spool of Thread	People & Things	
🧶	Ball of Yarn	People & Things	
🧷	Safety Pin	People & Things	
🧸	Teddy Bear	People & Things	
🧹	Broom	People & Things	
🧺	Basket	People & Things	
🧻	Roll of Paper	People & Things	
🧼	Bar of Soap	People & Things	
🧽	Sponge	People & Things	
🧾	Receipt	People & Things	
🧿	Nazar Amulet	People & Things	
🩰	Ballet Shoes	More Objects	
🩱	One Piece Swimsuit	More Objects	
🩲	Briefs	More Objects	
🩳	Shorts	More Objects	
🩴	Thong Sandal	More Objects	
🩵	Light Blue Heart	More Objects	
🩶	Grey Heart	More Objects	
🩷	Pink Heart	More Objects	
🩸	Drop of Blood	More Objects	
🩹	Adhesive Bandage	More Objects	
🩺	Stethoscope	More Objects	
🩻	X Ray	More Objects	
🩼	Crutch	More Objects	
🪀	Yo Yo	More Objects	
🪁	Kite	More Objects	
🪂	Parachute	More Objects	
🪃	Boomerang	More Objects	
🪄	Magic Wand	More Objects	
🪅	Pinata	More Objects	
🪆	Nesting Dolls	More Objects	
🪇	Maracas	More Objects	
🪈	Flute	More Objects	
🪉	Harp	More Objects	
🪏	Shovel	More Objects	
🪐	Ringed Planet	More Objects	
🪑	Chair	More Objects	
🪒	Razor	More Objects	
🪓	Axe	More Objects	
🪔	Diya Lamp	More Objects	
🪕	Banjo	More Objects	
🪖	Military Helmet	More Objects	
🪗	Accordion	More Objects	
🪘	Long Drum	More Objects	
🪙	Coin	More Objects	
🪚	Carpentry Saw	More Objects	
🪛	Screwdriver	More Objects	
🪜	Ladder	More Objects	
🪝	Hook	More Objects	
🪞	Mirror	More Objects	
🪟	Window	More Objects	
🪠	Plunger	More Objects	
🪡	Sewing Needle	More Objects	
🪢	Knot	More Objects	
🪣	Bucket	More Objects	
🪤	Mouse Trap	More Objects	
🪥	Toothbrush	More Objects	
🪦	Headstone	More Objects	
🪧	Placard	More Objects	
🪨	Rock	More Objects	
🪩	Mirror Ball	More Objects	
🪪	Identification Card	More Objects	
🪫	Low Battery	More Objects	
🪬	Hamsa	More Objects	
🪭	Folding Hand Fan	More Objects	
🪮	Hair Pick	More Objects	
🪯	Khanda	More Objects	
🪰	Fly	More Objects	
🪱	Worm	More Objects	
🪲	Beetle	More Objects	
🪳	Cockroach	More Objects	
🪴	Potted Plant	More Objects	
🪵	Wood	More Objects	
🪶	Feather	More Objects	
🪷	Lotus	More Objects	
🪸	Coral	More Objects	
🪹	Empty Nest	More Objects	
🪺	Nest with Eggs	More Objects	
🪻	Hyacinth	More Objects	
🪼	Jellyfish	More Objects	
🪽	Wing	More Objects	
🪾	Leafless Tree	More Objects	
🪿	Goose	More Objects	
🫀	Anatomical Heart	More Objects	
🫁	Lungs	More Objects	
🫂	People Hugging	More Objects	
🫃	Pregnant Man	More Objects	
🫄	Pregnant Person	More Objects	
🫅	Person with Crown	More Objects	
🫆	Fingerprint	More Objects	
🫎	Moose	More Objects	
🫏	Donkey	More Objects	
🫐	Blueberries	More Objects	
🫑	Bell Pepper	More Objects	
🫒	Olive	More Objects	
🫓	Flatbread	More Objects	
🫔	Tamale	More Objects	
🫕	Fondue	More Objects	
🫖	Teapot	More Objects	
🫗	Pouring Liquid	More Objects	
🫘	Beans	More Objects	
🫙	Jar	More Objects	
🫚	Ginger Root	More Objects	
🫛	Pea Pod	More Objects	
🫜	Root Vegetable	More Objects	
🫟	Splatter	More Objects	
🫠	Melting Face	More Objects	
🫡	Saluting Face	More Objects	salute
🫢	Face with Open Eyes and Hand Over Mouth	More Objects	
🫣	Face with Peeking Eye	More Objects	
🫤	Face with Diagonal Mouth	More Objects	
🫥	Dotted Line Face	More Objects	
🫦	Biting Lip	More Objects	
🫧	Bubbles	More Objects	
🫨	Shaking Face	More Objects	
🫩	Face with Bags Under Eyes	More Objects	
🫰	Hand with Index Finger and Thumb Crossed	More Objects	
🫱	Rightwards Hand	More Objects	
🫲	Leftwards Hand	More Objects	
🫳	Palm Down Hand	More Objects	
🫴	Palm Up Hand	More Objects	
🫵	Index Pointing At the Viewer	More Objects	
🫶	Heart Hands	More Objects	
🫷	Leftwards Pushing Hand	More Objects	
🫸	Rightwards Pushing Hand	More Objects	
☀️	Black Sun with Rays	Symbols	sun sunny
☁️	Cloud	Symbols	
☂️	Umbrella	Symbols	
☃️	Snowman	Symbols	
☄️	Comet	Symbols	
★️	Black Star	Symbols	
☆️	White Star	Symbols	
☎️	Black Telephone	Symbols	
☑️	Ballot Box with Check	Symbols	ballot box check
☕️	Hot Beverage	Symbols	coffee tea
☘️	Shamrock	Symbols	
☝️	White Up Pointing Index	Symbols	point up
☠️	Skull and Crossbones	Symbols	
☢️	Radioactive Sign	Symbols	
☣️	Biohazard Sign	Symbols	
☮️	Peace Symbol	Symbols	
☯️	Yin Yang	Symbols	
☹️	White Frowning Face	Symbols	
☺️	White Smiling Face	Symbols	smiling face classic
♀️	Female Sign	Symbols	
♂️	Male Sign	Symbols	
♈️	Aries	Symbols	
♉️	Taurus	Symbols	
♊️	Gemini	Symbols	
♋️	Cancer	Symbols	
♌️	Leo	Symbols	
♍️	Virgo	Symbols	
♎️	Libra	Symbols	
♏️	Scorpius	Symbols	
♐️	Sagittarius	Symbols	
♑️	Capricorn	Symbols	
♒️	Aquarius	Symbols	
♓️	Pisces	Symbols	
♟️	Black Chess Pawn	Symbols	
♠️	Black Spade Suit	Symbols	
♣️	Black Club Suit	Symbols	
♥️	Black Heart Suit	Symbols	heart suit love
♦️	Black Diamond Suit	Symbols	
♨️	Hot Springs	Symbols	
♻️	Black Universal Recycling Symbol	Symbols	
♿️	Wheelchair Symbol	Symbols	
⚒️	Hammer and Pick	Symbols	
⚓️	Anchor	Symbols	
⚔️	Crossed Swords	Symbols	
⚕️	Staff of Aesculapius	Symbols	
⚖️	Scales	Symbols	
⚗️	Alembic	Symbols	
⚙️	Gear	Symbols	
⚛️	Atom Symbol	Symbols	
⚜️	Fleur De Lis	Symbols	
⚠️	Warning Sign	Symbols	warning caution
⚡️	High Voltage Sign	Symbols	lightning bolt zap
⚪️	Medium White Circle	Symbols	
⚫️	Medium Black Circle	Symbols	
⚰️	Coffin	Symbols	
⚽️	Soccer Ball	Symbols	
⚾️	Baseball	Symbols	
⛄️	Snowman Without Snow	Symbols	
⛅️	Sun Behind Cloud	Symbols	
⛈️	Thunder Cloud and Rain	Symbols	
⛎️	Ophiuchus	Symbols	
⛏️	Pick	Symbols	
⛑️	Helmet with White Cross	Symbols	
⛔️	No Entry	Symbols	
⛩️	Shinto Shrine	Symbols	
⛪️	Church	Symbols	
⛰️	Mountain	Symbols	
⛱️	Umbrella on Ground	Symbols	
⛲️	Fountain	Symbols	
⛳️	Flag in Hole	Symbols	
⛴️	Ferry	Symbols	
⛵️	Sailboat	Symbols	
⛷️	Skier	Symbols	
⛸️	Ice Skate	Symbols	
⛹️	Person with Ball	Symbols	
⛺️	Tent	Symbols	
⛽️	Fuel Pump	Symbols	
✂️	Black Scissors	Symbols	
✅️	White Heavy Check Mark	Symbols	check done yes tick
✈️	Airplane	Symbols	airplane flight travel
✉️	Envelope	Symbols	
✊️	Raised Fist	Symbols	
✋️	Raised Hand	Symbols	
✌️	Victory Hand	Symbols	peace victory
✍️	Writing Hand	Symbols	
✏️	Pencil	Symbols	pencil edit write
✒️	Black Nib	Symbols	
✔️	Heavy Check Mark	Symbols	heavy check mark tick done
✖️	Heavy Multiplication X	Symbols	multiply x cross
✝️	Latin Cross	Symbols	
✡️	Star of David	Symbols	
✨️	Sparkles	Symbols	sparkles magic
✳️	Eight Spoked Asterisk	Symbols	
✴️	Eight Pointed Black Star	Symbols	
❄️	Snowflake	Symbols	
❇️	Sparkle	Symbols	
❌️	Cross Mark	Symbols	cross no wrong x
❎️	Negative Squared Cross Mark	Symbols	
❓️	Black Question Mark Ornament	Symbols	question mark
❔️	White Question Mark Ornament	Symbols	
❕️	White Exclamation Mark Ornament	Symbols	
❗️	Heavy Exclamation Mark Symbol	Symbols	exclamation
❣️	Heavy Heart Exclamation Mark Ornament	Symbols	
❤️	Heavy Black Heart	Symbols	heart love red
➕️	Heavy Plus Sign	Symbols	
➖️	Heavy Minus Sign	Symbols	
➗️	Heavy Division Sign	Symbols	
➡️	Black Rightwards Arrow	Symbols	arrow right
➰️	Curly Loop	Symbols	
➿️	Double Curly Loop	Symbols	
🇨🇳	Flag: China	Flags	flag china china chinese flag
🇺🇸	Flag: United States	Flags	flag united states usa america flag
🇬🇧	Flag: United Kingdom	Flags	flag united kingdom
🇯🇵	Flag: Japan	Flags	flag japan
🇰🇷	Flag: South Korea	Flags	flag south korea
🇸🇬	Flag: Singapore	Flags	flag singapore
🇭🇰	Flag: Hong Kong	Flags	flag hong kong
🇹🇼	Flag: Taiwan	Flags	flag taiwan
🇩🇪	Flag: Germany	Flags	flag germany
🇫🇷	Flag: France	Flags	flag france
🇦🇺	Flag: Australia	Flags	flag australia
🇨🇦	Flag: Canada	Flags	flag canada
🇮🇳	Flag: India	Flags	flag india
🇹🇭	Flag: Thailand	Flags	flag thailand
🇻🇳	Flag: Vietnam	Flags	flag vietnam
🇲🇾	Flag: Malaysia	Flags	flag malaysia
🇮🇩	Flag: Indonesia	Flags	flag indonesia
🇪🇺	Flag: European Union	Flags	flag european union
🇳🇿	Flag: New Zealand	Flags	flag new zealand
🇧🇷	Flag: Brazil	Flags	flag brazil
←	Leftwards Arrow	Arrows	arrow left back
↑	Upwards Arrow	Arrows	arrow up
→	Rightwards Arrow	Arrows	arrow right next
↓	Downwards Arrow	Arrows	arrow down
↔	Left Right Arrow	Arrows	
↕	Up Down Arrow	Arrows	
↖	North West Arrow	Arrows	
↗	North East Arrow	Arrows	
↘	South East Arrow	Arrows	
↙	South West Arrow	Arrows	
⇐	Leftwards Double Arrow	Arrows	
⇒	Rightwards Double Arrow	Arrows	
⇑	Upwards Double Arrow	Arrows	
⇓	Downwards Double Arrow	Arrows	
⇔	Left Right Double Arrow	Arrows	
↵	Downwards Arrow with Corner Leftwards	Arrows	
↩	Leftwards Arrow with Hook	Arrows	
↪	Rightwards Arrow with Hook	Arrows	
⤴	Arrow Pointing Rightwards Then Curving Upwards	Arrows	
⤵	Arrow Pointing Rightwards Then Curving Downwards	Arrows	
➜	Heavy Round Tipped Rightwards Arrow	Arrows	
➔	Heavy Wide Headed Rightwards Arrow	Arrows	
⟵	Long Leftwards Arrow	Arrows	
⟶	Long Rightwards Arrow	Arrows	
±	Plus Minus Sign	Math	plus minus
×	Multiplication Sign	Math	
÷	Division Sign	Math	
≈	Almost Equal to	Math	approximately about
≠	Not Equal to	Math	not equal
≤	Less Than Or Equal to	Math	
≥	Greater Than Or Equal to	Math	
∞	Infinity	Math	
√	Square Root	Math	
∑	N Ary Summation	Math	
∏	N Ary Product	Math	
∆	Increment	Math	
∂	Partial Differential	Math	
∫	Integral	Math	
∈	Element of	Math	
∉	Not An Element of	Math	
∩	Intersection	Math	
∪	Union	Math	
∀	For All	Math	
∃	There Exists	Math	
¬	Not Sign	Math	
∧	Logical and	Math	
∨	Logical Or	Math	
°	Degree Sign	Math	degree
‰	Per Mille Sign	Math	
¼	Vulgar Fraction One Quarter	Math	
½	Vulgar Fraction One Half	Math	
¾	Vulgar Fraction Three Quarters	Math	
²	Superscript Two	Math	
³	Superscript Three	Math	
¹	Superscript One	Math	
ⁿ	Superscript Latin Small Letter N	Math	
π	Greek Small Letter Pi	Math	
μ	Greek Small Letter Mu	Math	
Ω	Greek Capital Letter Omega	Math	
α	Greek Small Letter Alpha	Math	
β	Greek Small Letter Beta	Math	
γ	Greek Small Letter Gamma	Math	
δ	Greek Small Letter Delta	Math	
λ	Greek Small Letter Lamda	Math	
σ	Greek Small Letter Sigma	Math	
θ	Greek Small Letter Theta	Math	
€	Euro Sign	Currency	euro
£	Pound Sign	Currency	pound sterling
¥	Yen Sign	Currency	yen yuan rmb
₹	Indian Rupee Sign	Currency	
₩	Won Sign	Currency	won
₿	Bitcoin Sign	Currency	bitcoin
¢	Cent Sign	Currency	
₽	Ruble Sign	Currency	
₫	Dong Sign	Currency	
₪	New Sheqel Sign	Currency	
₺	Turkish Lira Sign	Currency	
₱	Peso Sign	Currency	
—	Em Dash	Punctuation	em dash
–	En Dash	Punctuation	en dash
…	Horizontal Ellipsis	Punctuation	ellipsis dots
«	Left Pointing Double Angle Quotation Mark	Punctuation	
»	Right Pointing Double Angle Quotation Mark	Punctuation	
“	Left Double Quotation Mark	Punctuation	
”	Right Double Quotation Mark	Punctuation	
‘	Left Single Quotation Mark	Punctuation	
’	Right Single Quotation Mark	Punctuation	
‚	Single Low 9 Quotation Mark	Punctuation	
„	Double Low 9 Quotation Mark	Punctuation	
•	Bullet	Punctuation	bullet dot
·	Middle Dot	Punctuation	
†	Dagger	Punctuation	
‡	Double Dagger	Punctuation	
§	Section Sign	Punctuation	
¶	Pilcrow Sign	Punctuation	
¿	Inverted Question Mark	Punctuation	
¡	Inverted Exclamation Mark	Punctuation	
※	Reference Mark	Punctuation	
‼	Double Exclamation Mark	Punctuation	
⁇	Double Question Mark	Punctuation	
⌘	Place of Interest Sign	Keys	command cmd key
⌥	Option Key	Keys	option alt key
⌃	Up Arrowhead	Keys	control ctrl key
⇧	Upwards White Arrow	Keys	shift key
⇥	Rightwards Arrow to Bar	Keys	
⎋	Broken Circle with Northwest Arrow	Keys	
⌫	Erase to the Left	Keys	delete backspace key
⌦	Erase to the Right	Keys	
⏎	Return Symbol	Keys	return enter key
␣	Open Box	Keys	
⇪	Upwards White Arrow From Bar	Keys	
⏏	Eject Symbol	Keys	
✓	Check Mark	Marks	check mark tick
✗	Ballot X	Marks	ballot x cross
©	Copyright Sign	Marks	copyright
®	Registered Sign	Marks	
™	Trade Mark Sign	Marks	trademark
№	Numero Sign	Marks	
℃	Degree Celsius	Marks	
℉	Degree Fahrenheit	Marks	
♪	Eighth Note	Marks	
♫	Beamed Eighth Notes	Marks	
✦	Black Four Pointed Star	Marks	
◆	Black Diamond	Marks	
◇	White Diamond	Marks	
■	Black Square	Marks	
□	White Square	Marks	
●	Black Circle	Marks	
○	White Circle	Marks	
▲	Black Up Pointing Triangle	Marks	
▼	Black Down Pointing Triangle	Marks	
◀	Black Left Pointing Triangle	Marks	
▶	Black Right Pointing Triangle	Marks	
◉	Fisheye	Marks	
◎	Bullseye	Marks	
▪	Black Small Square	Marks	
▫	White Small Square	Marks	
"""
}
