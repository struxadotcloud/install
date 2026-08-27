Vagrant.configure("2") do |config|
  boxes = {
    "ubuntu2204" => { box: "generic/ubuntu2204", pin: ENV["STRUXA_TEST_PIN_TAG"] },
    "ubuntu2404" => { box: "generic/ubuntu2404", pin: nil },
    "debian13"   => { box: "generic/debian13",   pin: nil },
  }

  boxes.each do |name, spec|
    config.vm.define name do |vm|
      vm.vm.box = spec[:box]
      vm.vm.hostname = "struxa-#{name}"

      vm.vm.provider "virtualbox" do |vb|
        vb.memory = 4096
        vb.cpus = 2
      end

      vm.vm.synced_folder ".", "/vagrant"

      vm.vm.provision "shell",
        path: "provisioning/provision.sh",
        privileged: true,
        env: {
          "STRUXA_TEST_PIN_TAG" => spec[:pin].to_s,
        }
    end
  end
end
