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

import UIKit
import CocoaLumberjack
import RealmSwift

class QuotaInfoCell: UITableViewCell {
    static let cellName = "QuotaInfoCell-CloudStorage"

    var owner = ""
    
    var delegate: QuotaCellDelegate?
    
    var imagesWidthMultiplier: CGFloat = 0.0
    var videosWidthMultiplier: CGFloat = 0.0
    var filesWidthMultiplier: CGFloat = 0.0
    var audioWidthMultiplier: CGFloat = 0.0
    
    var firstDelimiterWidth: CGFloat = 1
    var secondDelimeterWidth: CGFloat = 1
    var thirdDelimeterWidth: CGFloat = 1
    
    let labelsStack: UIStackView = {
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.alignment = .fill
        stack.distribution = .equalSpacing
        stack.spacing = 4
        stack.axis = .horizontal
        
        return stack
    }()
    
    let quotaNameLabel: UILabel = {
        let label = UILabel()
        label.textColor = .black
        label.textAlignment = .left
        label.font = .systemFont(ofSize: 18)
        
        return label
    }()
    
    let quotaLabel: UILabel = {
        let label = UILabel()
        label.textColor = .gray
        label.textAlignment = .right
        label.font = .systemFont(ofSize: 16)
        
        return label
    }()
    
    let progressMask: UIView = {
        let mask = UIView()
        mask.backgroundColor = .blue
        mask.layer.cornerRadius = 7
        
        return mask
    }()
    
    let mainProgressView: UIView = {
        let view = UIView()
        view.backgroundColor = .groupTableViewBackground
        view.translatesAutoresizingMaskIntoConstraints = false
        
        return view
    }()
    
    let imagesProgressView: UIView = {
        let view = UIView()
        view.backgroundColor = .systemOrange
        view.translatesAutoresizingMaskIntoConstraints = false
        
        return view
    }()
    
    let videosProgressView: UIView = {
        let view = UIView()
        view.backgroundColor = .systemPurple
        view.translatesAutoresizingMaskIntoConstraints = false
        
        return view
    }()
    
    let filesProgressView: UIView = {
        let view = UIView()
        view.backgroundColor = .systemGreen
        view.translatesAutoresizingMaskIntoConstraints = false
        
        return view
    }()
    
    let voiceProgressView: UIView = {
        let view = UIView()
        view.backgroundColor = .systemBlue
        view.translatesAutoresizingMaskIntoConstraints = false
        
        return view
    }()
    
    let whiteDelimeterViewFirst: UIView = {
        let view = UIView()
        view.backgroundColor = .white
        view.translatesAutoresizingMaskIntoConstraints = false
        
        return view
    }()
    
    let whiteDelimeterViewSecond: UIView = {
        let view = UIView()
        view.backgroundColor = .white
        view.translatesAutoresizingMaskIntoConstraints = false
        
        return view
    }()
    
    let whiteDelimeterViewThird: UIView = {
        let view = UIView()
        view.backgroundColor = .white
        view.translatesAutoresizingMaskIntoConstraints = false
        
        return view
    }()
    
    let imagesIndicator: UIView = {
        let view = UIView()
        view.backgroundColor = .systemOrange
        view.layer.cornerRadius = 3
        view.translatesAutoresizingMaskIntoConstraints = false
        
        return view
    }()
    
    let imagesLabel: UILabel = {
        let label = UILabel()
        label.text = "Images".localizeString(id: "images", arguments: [])
        label.textAlignment = .left
        label.font = .systemFont(ofSize: 14)
        label.translatesAutoresizingMaskIntoConstraints = false
        
        return label
    }()
    
    let videosIndicator: UIView = {
        let view = UIView()
        view.backgroundColor = .systemPurple
        view.layer.cornerRadius = 3
        view.translatesAutoresizingMaskIntoConstraints = false
        
        return view
    }()
    
    let videosLabel: UILabel = {
        let label = UILabel()
        label.text = "Videos".localizeString(id: "videos", arguments: [])
        label.textAlignment = .left
        label.font = .systemFont(ofSize: 14)
        label.translatesAutoresizingMaskIntoConstraints = false
        
        return label
    }()
    
    let filesIndicator: UIView = {
        let view = UIView()
        view.backgroundColor = .systemGreen
        view.layer.cornerRadius = 3
        view.translatesAutoresizingMaskIntoConstraints = false
        
        return view
    }()
    
    let filesLabel: UILabel = {
        let label = UILabel()
        label.text = "Files".localizeString(id: "files", arguments: [])
        label.textAlignment = .left
        label.font = .systemFont(ofSize: 14)
        label.translatesAutoresizingMaskIntoConstraints = false
        
        return label
    }()
    
    let voiceIndicator: UIView = {
        let view = UIView()
        view.backgroundColor = .systemBlue
        view.layer.cornerRadius = 3
        view.translatesAutoresizingMaskIntoConstraints = false
        
        return view
    }()
    
    let voiceLabel: UILabel = {
        let label = UILabel()
        label.text = "Voice".localizeString(id: "voice", arguments: [])
        label.textAlignment = .left
        label.font = .systemFont(ofSize: 14)
        label.translatesAutoresizingMaskIntoConstraints = false
        
        return label
    }()
    
    let imagesStack: UIStackView = {
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.alignment = .center
        stack.distribution = .fill
        stack.spacing = 8
        stack.axis = .horizontal
        
        return stack
    }()
    
    let videosStack: UIStackView = {
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.alignment = .center
        stack.distribution = .fill
        stack.spacing = 8
        stack.axis = .horizontal
        
        return stack
    }()
    
    let filesStack: UIStackView = {
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.alignment = .center
        stack.distribution = .fill
        stack.spacing = 8
        stack.axis = .horizontal
        
        return stack
    }()
    
    let voiceStack: UIStackView = {
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.alignment = .center
        stack.distribution = .fill
        stack.spacing = 8
        stack.axis = .horizontal
        
        return stack
    }()
    
    let activityIndicator: UIActivityIndicatorView = {
        let view = UIActivityIndicatorView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.startAnimating()
        view.hidesWhenStopped = true
        
        return view
    }()
    
    func setup(title: String, owner: String, requiresDataFromServer: Bool = false, quotaDelegate: QuotaCellDelegate?) {
        self.owner = owner
        self.delegate = quotaDelegate

        quotaNameLabel.text = title
        
        addSubview(activityIndicator)
        makeActivityIndicatorConstraints()
        
        delegate?.getQuotaInfo(requiresDataFromServer: requiresDataFromServer) {
            rawImages, rawVideos, rawFiles, rawVoices, quotaRaw, quota, used in
            
            self.setupMainInfoViews(rawImages: rawImages,
                                    rawVideos: rawVideos,
                                    rawFiles: rawFiles,
                                    rawVoices: rawVoices,
                                    quotaRaw: quotaRaw,
                                    quota: quota,
                                    used: used)
        }
    }
    
    func reloadData(callback: @escaping (() -> Void)) {
//        activityIndicator.startAnimating()
//        quotaLabel.alpha = 0
//        mainProgressView.alpha = 0
//        imagesStack.alpha = 0
//        videosStack.alpha = 0
//        filesStack.alpha = 0
//        voiceStack.alpha = 0
        
        delegate?.getQuotaInfo(requiresDataFromServer: true) { [self]
            rawImages, rawVideos, rawFiles, rawVoices, quotaRaw, quota, used in
            
            quotaLabel.text = used + " of ".localizeString(id: "of", arguments: []) + quota
            
            imagesWidthMultiplier = CGFloat(rawImages) / CGFloat(quotaRaw)
            videosWidthMultiplier = CGFloat(rawVideos) / CGFloat(quotaRaw)
            filesWidthMultiplier = CGFloat(rawFiles) / CGFloat(quotaRaw)
            audioWidthMultiplier = CGFloat(rawVoices) / CGFloat(quotaRaw)
            
            setupDelimeters()
            setupViews()
            
//            quotaLabel.alpha = 1
//            mainProgressView.alpha = 1
//            imagesStack.alpha = 1
//            videosStack.alpha = 1
//            filesStack.alpha = 1
//            voiceStack.alpha = 1
            callback()
        }
    }
    
    private func setupMainInfoViews(rawImages: Int, rawVideos: Int, rawFiles: Int, rawVoices: Int,
                                    quotaRaw: Int, quota: String, used: String) {
        self.quotaLabel.text = used + " of ".localizeString(id: "of", arguments: []) + quota
        
        imagesWidthMultiplier = CGFloat(rawImages) / CGFloat(quotaRaw)
        videosWidthMultiplier = CGFloat(rawVideos) / CGFloat(quotaRaw)
        filesWidthMultiplier = CGFloat(rawFiles) / CGFloat(quotaRaw)
        audioWidthMultiplier = CGFloat(rawVoices) / CGFloat(quotaRaw)
        
        addSubview(labelsStack)
        labelsStack.addArrangedSubview(quotaNameLabel)
        labelsStack.addArrangedSubview(quotaLabel)
        
        setupDelimeters()
        
        addSubview(mainProgressView)
        makeMainConstraints()
        
        progressMask.frame = CGRect(x: 0, y: 0, width: frame.width - 30, height: 20)
        mainProgressView.mask = progressMask
        
        setupViews()
        
        activityIndicator.stopAnimating()
    }
    
    
    private func setupDelimeters() {
        if imagesWidthMultiplier == 0 {
            firstDelimiterWidth = 0
        } else {
            if videosWidthMultiplier == 0 && filesWidthMultiplier == 0 && audioWidthMultiplier == 0 {
                firstDelimiterWidth = 0
            }
        }
        
        if videosWidthMultiplier == 0 {
            secondDelimeterWidth = 0
        } else {
            if filesWidthMultiplier == 0 && audioWidthMultiplier == 0 {
                secondDelimeterWidth = 0
            }
        }
        
        if filesWidthMultiplier == 0 {
            thirdDelimeterWidth = 0
        } else {
            if audioWidthMultiplier == 0 {
                thirdDelimeterWidth = 0
            }
        }
    }
    
    private func setupViews() {
        if imagesWidthMultiplier != 0 {
            mainProgressView.addSubview(imagesProgressView)
            mainProgressView.addSubview(whiteDelimeterViewFirst)
            
            addSubview(imagesStack)
            imagesStack.addArrangedSubview(imagesIndicator)
            imagesStack.addArrangedSubview(imagesLabel)
            makeImagesConstraints()
        } else {
            mainProgressView.addSubview(whiteDelimeterViewFirst)
            makeFirstDelimeterConstraints()
        }
        
        if videosWidthMultiplier != 0 {
   
            mainProgressView.addSubview(videosProgressView)
            mainProgressView.addSubview(whiteDelimeterViewSecond)
            
            addSubview(videosStack)
            videosStack.addArrangedSubview(videosIndicator)
            videosStack.addArrangedSubview(videosLabel)
            
            if imagesWidthMultiplier != 0 {
                makeVideosConstraints(delimeter: whiteDelimeterViewFirst, stack: imagesStack)
            } else {
                makeVideosConstraints(delimeter: whiteDelimeterViewFirst, stack: self)
            }
        }
        
        if filesWidthMultiplier != 0 {
            mainProgressView.addSubview(filesProgressView)
            mainProgressView.addSubview(whiteDelimeterViewThird)
            
            addSubview(filesStack)
            filesStack.addArrangedSubview(filesIndicator)
            filesStack.addArrangedSubview(filesLabel)
            
            if videosWidthMultiplier != 0 {
                makeFilesConstraints(delimeter: whiteDelimeterViewSecond, stack: videosStack)
            } else if imagesWidthMultiplier != 0 {
                makeFilesConstraints(delimeter: whiteDelimeterViewFirst, stack: imagesStack)
            } else {
                makeFilesConstraints(delimeter: whiteDelimeterViewFirst, stack: self)
            }
        }
        
        if audioWidthMultiplier != 0 {
            mainProgressView.addSubview(voiceProgressView)
            
            addSubview(voiceStack)
            voiceStack.addArrangedSubview(voiceIndicator)
            voiceStack.addArrangedSubview(voiceLabel)
            
            if filesWidthMultiplier != 0 {
                makeVoiceConstraints(delimeter: whiteDelimeterViewThird, stack: filesStack)
            } else if videosWidthMultiplier != 0 {
                makeVoiceConstraints(delimeter: whiteDelimeterViewSecond, stack: videosStack)
            } else if imagesWidthMultiplier != 0 {
                makeVoiceConstraints(delimeter: whiteDelimeterViewFirst, stack: imagesStack)
            } else {
                makeVoiceConstraints(delimeter: whiteDelimeterViewFirst, stack: self)
            }
        }
    }
    
    private func makeActivityIndicatorConstraints() {
        NSLayoutConstraint.activate([
            activityIndicator.centerXAnchor.constraint(equalTo: centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 0)
        ])
    }
    
    private func makeMainConstraints() {
        NSLayoutConstraint.activate([
            labelsStack.leftAnchor.constraint(equalTo: leftAnchor, constant: 15),
            labelsStack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            labelsStack.rightAnchor.constraint(equalTo: rightAnchor,constant: -15),
            
            mainProgressView.leftAnchor.constraint(equalTo: labelsStack.leftAnchor),
            mainProgressView.topAnchor.constraint(equalTo: labelsStack.bottomAnchor, constant: 15),
            mainProgressView.rightAnchor.constraint(equalTo: labelsStack.rightAnchor),
            mainProgressView.heightAnchor.constraint(equalToConstant: 20),
        ])
    }
    
    func makeImagesConstraints() {
        NSLayoutConstraint.activate([
            imagesProgressView.leftAnchor.constraint(equalTo: mainProgressView.leftAnchor),
            imagesProgressView.topAnchor.constraint(equalTo: mainProgressView.topAnchor),
            imagesProgressView.bottomAnchor.constraint(equalTo: mainProgressView.bottomAnchor),
            imagesProgressView.widthAnchor.constraint(equalTo: mainProgressView.widthAnchor,
                                                      multiplier: imagesWidthMultiplier,
                                                      constant: -3/4),
            imagesProgressView.widthAnchor.constraint(greaterThanOrEqualToConstant: 1),
            
            whiteDelimeterViewFirst.leftAnchor.constraint(equalTo: imagesProgressView.rightAnchor),
            whiteDelimeterViewFirst.topAnchor.constraint(equalTo: imagesProgressView.topAnchor),
            whiteDelimeterViewFirst.bottomAnchor.constraint(equalTo: imagesProgressView.bottomAnchor),
            whiteDelimeterViewFirst.widthAnchor.constraint(equalToConstant: firstDelimiterWidth),
            
            imagesStack.leftAnchor.constraint(equalTo: leftAnchor, constant: 20),
            imagesStack.topAnchor.constraint(equalTo: mainProgressView.bottomAnchor, constant: 12),
            
            imagesIndicator.widthAnchor.constraint(equalToConstant: 6),
            imagesIndicator.heightAnchor.constraint(equalToConstant: 6),
        ])
    }
    
    func makeFirstDelimeterConstraints(view: UIView) {
        NSLayoutConstraint.activate([
            
        ])
    }
    
    func makeFirstDelimeterConstraints() {
        NSLayoutConstraint.activate([
            whiteDelimeterViewFirst.leftAnchor.constraint(equalTo: mainProgressView.leftAnchor),
            whiteDelimeterViewFirst.topAnchor.constraint(equalTo: mainProgressView.topAnchor),
            whiteDelimeterViewFirst.bottomAnchor.constraint(equalTo: mainProgressView.bottomAnchor),
            whiteDelimeterViewFirst.widthAnchor.constraint(equalToConstant: firstDelimiterWidth)
        ])
    }
    
    func makeVideosConstraints(delimeter: UIView, stack: UIView) {
        NSLayoutConstraint.activate([
            videosProgressView.leftAnchor.constraint(equalTo: delimeter.rightAnchor),
            videosProgressView.topAnchor.constraint(equalTo: delimeter.topAnchor),
            videosProgressView.bottomAnchor.constraint(equalTo: delimeter.bottomAnchor),
            videosProgressView.widthAnchor.constraint(equalTo: mainProgressView.widthAnchor,
                                                      multiplier: videosWidthMultiplier,
                                                      constant: -3/4),
            videosProgressView.widthAnchor.constraint(greaterThanOrEqualToConstant: 1),
            
            whiteDelimeterViewSecond.leftAnchor.constraint(equalTo: videosProgressView.rightAnchor),
            whiteDelimeterViewSecond.topAnchor.constraint(equalTo: videosProgressView.topAnchor),
            whiteDelimeterViewSecond.bottomAnchor.constraint(equalTo: videosProgressView.bottomAnchor),
            whiteDelimeterViewSecond.widthAnchor.constraint(equalToConstant: secondDelimeterWidth),
            
            videosStack.leftAnchor.constraint(equalTo: stack.rightAnchor, constant: 20),
            videosStack.topAnchor.constraint(equalTo: mainProgressView.bottomAnchor, constant: 12),
            
            videosIndicator.widthAnchor.constraint(equalToConstant: 6),
            videosIndicator.heightAnchor.constraint(equalToConstant: 6)
        ])
    }
    
    func makeFilesConstraints(delimeter: UIView, stack: UIView) {
        NSLayoutConstraint.activate([
            filesProgressView.leftAnchor.constraint(equalTo: delimeter.rightAnchor),
            filesProgressView.topAnchor.constraint(equalTo: delimeter.topAnchor),
            filesProgressView.bottomAnchor.constraint(equalTo: delimeter.bottomAnchor),
            filesProgressView.widthAnchor.constraint(equalTo: mainProgressView.widthAnchor,
                                                     multiplier: filesWidthMultiplier,
                                                     constant: -3/4),
            filesProgressView.widthAnchor.constraint(greaterThanOrEqualToConstant: 1),
            
            whiteDelimeterViewThird.leftAnchor.constraint(equalTo: filesProgressView.rightAnchor),
            whiteDelimeterViewThird.topAnchor.constraint(equalTo: filesProgressView.topAnchor),
            whiteDelimeterViewThird.bottomAnchor.constraint(equalTo: filesProgressView.bottomAnchor),
            whiteDelimeterViewThird.widthAnchor.constraint(equalToConstant: thirdDelimeterWidth),
            
            filesStack.leftAnchor.constraint(equalTo: stack.rightAnchor, constant: 20),
            filesStack.topAnchor.constraint(equalTo: mainProgressView.bottomAnchor, constant: 12),
            
            filesIndicator.widthAnchor.constraint(equalToConstant: 6),
            filesIndicator.heightAnchor.constraint(equalToConstant: 6)
        ])
    }
    
    func makeVoiceConstraints(delimeter: UIView, stack: UIView) {
        NSLayoutConstraint.activate([
            voiceProgressView.leftAnchor.constraint(equalTo: delimeter.rightAnchor),
            voiceProgressView.topAnchor.constraint(equalTo: delimeter.topAnchor),
            voiceProgressView.bottomAnchor.constraint(equalTo: delimeter.bottomAnchor),
            voiceProgressView.widthAnchor.constraint(equalTo: mainProgressView.widthAnchor,
                                                     multiplier: audioWidthMultiplier,
                                                     constant: -3/4),
            voiceProgressView.widthAnchor.constraint(greaterThanOrEqualToConstant: 1),
            
            voiceStack.leftAnchor.constraint(equalTo: stack.rightAnchor, constant: 20),
            voiceStack.topAnchor.constraint(equalTo: mainProgressView.bottomAnchor, constant: 12),
            
            voiceIndicator.widthAnchor.constraint(equalToConstant: 6),
            voiceIndicator.heightAnchor.constraint(equalToConstant: 6)
        ])
    }

    override func awakeFromNib() {
        super.awakeFromNib()
    }

    override func setSelected(_ selected: Bool, animated: Bool) {
        super.setSelected(selected, animated: animated)

    }
    
    override func prepareForReuse() {
        super.prepareForReuse()
    }
}
