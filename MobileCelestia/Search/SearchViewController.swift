//
// SearchViewController.swift
//
// Copyright © 2020 Celestia Development Team. All rights reserved.
//
// This program is free software; you can redistribute it and/or
// modify it under the terms of the GNU General Public License
// as published by the Free Software Foundation; either version 2
// of the License, or (at your option) any later version.
//

import UIKit

import CelestiaCore

fileprivate struct SearchResult {
    let name: String
}

fileprivate struct SearchResultSection {
    let title: String?
    let results: [SearchResult]
}

class SearchViewController: UIViewController {

    private lazy var tableView = UITableView(frame: .zero, style: .plain)

    private lazy var searchController = UISearchController(searchResultsController: nil)

    private var searchQueue = OperationQueue()

    private var resultSections: [SearchResultSection] = []

    private let selected: (CelestiaSelection) -> Void

    private var shouldActivate = true

    init(selected: @escaping (CelestiaSelection) -> Void) {
        self.selected = selected
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = UIView()
        view.backgroundColor = .darkBackground

        title = CelestiaString("Search", comment: "")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        setup()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        if shouldActivate {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                _ = self?.searchController.searchBar.becomeFirstResponder()
            }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillAppear(animated)

        shouldActivate = searchController.searchBar.isFirstResponder
    }

    deinit {
        searchQueue.cancelAllOperations()
    }
}

private extension SearchViewController {
    func setup() {
        searchQueue.maxConcurrentOperationCount = 1

        view.addSubview(tableView)
        tableView.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])

        tableView.backgroundColor = .clear
        tableView.alwaysBounceVertical = false
        tableView.separatorColor = .darkSeparator

        tableView.register(SettingTextCell.self, forCellReuseIdentifier: "Text")
        tableView.dataSource = self
        tableView.delegate = self

        definesPresentationContext = true
        searchController.searchResultsUpdater = self

        if #available(iOS 9.1, *) {
            searchController.obscuresBackgroundDuringPresentation = false
        } else {
            searchController.dimsBackgroundDuringPresentation = false
        }
        let searchBar = searchController.searchBar
        searchBar.keyboardAppearance = .dark
        searchBar.delegate = self
        if #available(iOS 11.0, *) {
            /* system attached searchbar */
            navigationItem.searchController = searchController
            navigationItem.hidesSearchBarWhenScrolling = false

            tableView.topAnchor.constraint(equalTo: view.topAnchor).isActive = true
        } else {
            /* setup search bar */
            let container = UIView()
            container.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(container)
            NSLayoutConstraint.activate([
                  container.topAnchor.constraint(equalTo: view.topAnchor),
                  container.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                  container.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                  container.bottomAnchor.constraint(equalTo: tableView.topAnchor),
                  container.heightAnchor.constraint(equalToConstant: searchBar.bounds.height)
            ])
            container.addSubview(searchBar)

            for view in searchBar.subviews.last!.subviews {
                if type(of: view) == NSClassFromString("UISearchBarBackground") {
                    view.alpha = 0.1
                }
            }
        }
    }
}

extension SearchViewController: UITableViewDataSource, UITableViewDelegate {
    func numberOfSections(in tableView: UITableView) -> Int {
        return resultSections.count
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return resultSections[section].results.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let result = resultSections[indexPath.section].results[indexPath.row]
        let cell = tableView.dequeueReusableCell(withIdentifier: "Text", for: indexPath) as! SettingTextCell
        cell.title = result.name
        return cell
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return resultSections[section].title
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return 44
    }

    func tableView(_ tableView: UITableView, willDisplayHeaderView view: UIView, forSection section: Int) {
        if let header = view as? UITableViewHeaderFooterView {
            header.textLabel?.textColor = UIColor.darkPlainHeaderLabel
            header.backgroundView = UIView()
            header.backgroundView?.backgroundColor = .darkPlainHeaderBackground
        }
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        view.endEditing(true)

        tableView.deselectRow(at: indexPath, animated: true)
        let selection = resultSections[indexPath.section].results[indexPath.row]
        itemSelected(with: selection.name)
    }
}

extension SearchViewController: UISearchBarDelegate {
    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
        guard let text = searchBar.text, !text.isEmpty, resultSections.reduce(0, { $0 + $1.results.count }) == 0 else { return }
        itemSelected(with: text)
    }

    private func itemSelected(with name: String) {
        let sim = CelestiaAppCore.shared.simulation
        let object = sim.findObject(from: name)
        guard !object.isEmpty else {
            showError(CelestiaString("Object not found", comment: ""))
            return
        }

        selected(object)
    }
}

extension SearchViewController: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {
        guard searchController.isActive else { return }

        guard let text = searchController.searchBar.text, !text.isEmpty else {
            resultSections = []
            tableView.reloadData()
            return
        }

        searchQueue.cancelAllOperations()
        searchQueue.addOperation { [weak self] in
            guard let self = self else { return }
            let results = self.search(with: text)
            DispatchQueue.main.async {
                guard text == self.searchController.searchBar.text else { return }
                self.resultSections = results
                self.tableView.reloadData()
            }
        }
    }
}

extension SearchViewController {
    private func search(with text: String) -> [SearchResultSection] {
        let simulation = CelestiaAppCore.shared.simulation
        return [SearchResultSection(title: nil, results: simulation.completion(for: text).map { SearchResult(name: $0) })]
    }
}
