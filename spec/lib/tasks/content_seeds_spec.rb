require "rails_helper"

describe "content_seeds tasks" do
  let(:fixture_root) { Rails.root.join("spec/fixtures/content_seeds") }
  let(:step_tasks) { ContentSeeds::Importer::STEPS.map { |step| "content_seeds:import:#{step}" } }

  before do
    create(:administrator)
    allow(ContentSeeds::Importer).to receive(:new).and_wrap_original do |original, **kwargs|
      original.call(**kwargs, root: fixture_root)
    end
    (step_tasks + ["content_seeds:import"]).each { |task| Rake::Task[task].reenable }
  end

  it "defines one task per import step, numbered in order, plus the general one" do
    step_tasks.each_with_index do |task, index|
      expect(Rake::Task[task].comment).to include("step #{index + 1} of 9")
    end
    expect(Rake::Task["content_seeds:import"].comment).to include("9 import steps in order")
  end

  it "runs a single step with content_seeds:import:<step>" do
    Rake.application.invoke_task("content_seeds:import:blobs[sample]")

    expect(ActiveStorage::Blob.where(key: "vpw5ynbpkgjomwwqgiebq3q3l9rn")).to exist
    expect(SiteCustomization::Page.find_by(slug: "imported-page")).to be(nil)
  end

  it "runs every step with content_seeds:import" do
    Rake.application.invoke_task("content_seeds:import[sample]")

    expect(SiteCustomization::Page.find_by(slug: "imported-page")).to be_present
    expect(Widget::Card.header.count).to eq 1
    expect(I18nContent.find_by(key: "imported.section.title")).to be_present
  end

  it "exits with status 1 when a step fails" do
    expect { Rake.application.invoke_task("content_seeds:import:site_images[sample]") }
      .to raise_error(SystemExit) { |error| expect(error.status).to eq 1 }
  end
end
