require "rails_helper"

describe "Homepage", :admin do
  before do
    Setting["homepage.widgets.feeds.proposals"] = false
    Setting["homepage.widgets.feeds.debates"] = false
    Setting["homepage.widgets.feeds.processes"] = false
    Setting["feature.user.recommendations"] = false
  end

  let(:user) { create(:user) }

  scenario "Cards" do
    card1 = create(:widget_card, label: "Card1 label",
                                 title: "Card1 text",
                                 description: "Card1 description",
                                 link_text: "Link1 text",
                                 link_url: "consul1.dev")

    card2 = create(:widget_card, label: "Card2 label",
                                 title: "Card2 text",
                                 description: "Card2 description",
                                 link_text: "Link2 text",
                                 link_url: "consul2.dev")

    visit root_path

    expect(page).to have_css(".card", count: 2)

    within("#widget_card_#{card1.id}") do
      expect(page).to have_content("Card1 text")
      expect(page).to have_content("Card1 description")
      expect(page).to have_content("Link1 text")
      expect(page).to have_link(href: "consul1.dev")
      expect(page).to have_css("img[alt='#{card1.image.title}']")
    end

    within("#widget_card_#{card2.id}") do
      expect(page).to have_content("Card2 text")
      expect(page).to have_content("Card2 description")
      expect(page).to have_content("Link2 text")
      expect(page).to have_link(href: "consul2.dev")
      expect(page).to have_css("img[alt='#{card2.image.title}']")
    end
  end
end
