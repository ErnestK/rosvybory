# -*- encoding : utf-8 -*-
ActiveAdmin.register UserApp do
  decorate_with UserAppDecorator

  actions :all, :except => [:destroy, :new]

  menu :if => proc{ can? :read, UserApp }

  scope "Все", :all
  UserApp.state_machine.states.each do |state|
    scope state.human_name, :default => (state.name.to_s == "pending") do |items|
      items.with_state(state.name)
    end
  end

  scope 'Телефон в черном списке' do |items|
    items.where('EXISTS (SELECT * FROM blacklists WHERE phone=user_apps.phone)')
  end

  batch_action :group_accept

  action_item :only => [:index] do
    if can?(:import, resource_class)
      link_to('Загрузить из Excel', xls_import_control_user_apps_path)
    end
  end

  collection_action :xls_import, :method => :get do
    authorize! :import, UserApp
    @many_apps = ManyUserAppsForm.new(current_user.organisation)
  end

  collection_action :process_xls, :method => :post do
    authorize! :import, UserApp
    @many_apps = ManyUserAppsForm.new(current_user.organisation, params[:many_apps])
    @many_apps.save
    render "control/user_apps/xls_import"
  end

  member_action :do_reject, method: :post do
    if params[:reason].present?
      resource.transaction do
        resource.reject(false)
        ActiveAdmin::Comment.find_for_resource_in_namespace(resource, active_admin_namespace.name).create do |comment|
          comment.body = params[:reason].strip
          comment.author = current_active_admin_user
        end
        resource.save(validate: false)
      end
      render json: { success: true, id: resource.id }
    else
      render :action => :reject, :layout => false if request.xhr?
    end
  end

  member_action :reject, method: :get do
    @user_app = resource
    render :layout => false if request.xhr?
  end

  member_action :spam, method: :post do
    SpamReportingService.report(resource)
    redirect_to :action => :index
  end

  member_action :confirm_app, method: :post do
    begin
      resource.confirm_phone! unless resource.phone_verified?
      resource.confirm_email! unless resource.confirmed?
      render json: { success: true }
    rescue
      render json: { error: $!.to_s }
    end
  end

  action_item only: [:edit, :show] do
    link_to('Отклонить', reject_control_user_app_path(user_app), method: :post, class: 'reject_link') unless resource.rejected?
  end

  action_item only: [:edit, :show] do
    link_to('Это спам', spam_control_user_app_path(user_app), method: :post, 'data-confirm' => 'Заявка будет удалена, а номер телефона добавлен в черный список, продолжить?')
  end

  action_item only: [:edit, :show] do
    link_to('Принять', new_user_path(user_app_id: resource.id), data: {"user-app-id" => resource.id}, class: "member_link accept_link")  unless resource.approved?
  end

  #scope :all, :default => true
  #scope :trash
  #scope :accepted
  #scope :unchecked
  #
  ## Filterable attributes on the index screen

  filter :created_at
  filter :adm_region , :as => :select, :collection => proc { Region.adm_regions.all }
  filter :region, :as => :select, :collection => proc { Region.mun_regions.all }
  #так красиво разбивается по округам, но при фильтрации не устанавливает значение в текущее после перезагрузки страницы, это может сбить с толку
  #filter :region, :as => :select, :collection => proc { option_groups_from_collection_for_select(Region.adm_regions, :regions, :name, :id, :name) }


  filter   :full_name
  filter   :sex_male, :as => :select, :collection => [['М', true], ['Ж', false]]
  filter   :phone
  filter   :email
  filter   :uic #, :as => :numeric_range


  filter   :experience_count
  #column(:previous_statuses) {|user_app| status_human_readable user_app.previous_statuses}

  #column("Согласен войти в резерв УИКов") {|user_app| user_app.can_be_prg_reserve ? "Да":"Нет"}
  #column(:can_be_coord_region) {|user_app| user_app.can_be_coord_region ? "Да":"Нет"}
  #
  filter   :has_car
  filter   :has_video
  #
  #column(:social_accounts) {|user_app| raw social_accounts_readable(user_app) }
  filter   :extra
  #column(:legal_status) {|user_app| legal_status_human_readable user_app.legal_status}

  #column(:legal_status) {|user_app| user_app.legal_status & UserApp::LEGAL_STATUS_YES ? "Да":"Нет"}
  #column("Адвокатский статус") {|user_app| user_app.legal_status == UserApp::LEGAL_STATUS_LAWYER ? "Да":"Нет"}
  #column(:desired_statuses) {|user_app| status_human_readable user_app.desired_statuses}
  #
  filter   :year_born, :as => :numeric_range
  #column(:sex_male) {|user_app| user_app.sex_male ? "М":"Ж"}
  filter   :organisation
  filter   :ip
  filter   :useragent

  #preserve_default_filters!

  #scope :all, :default => true
  #Region.adm_regions.all.each do |adm_region|
  #  scope adm_region.name do |items|
  #    items.where(:adm_region => adm_region)
  #  end
  #end

  config.sort_order = "id_desc"
  controller do
    def scoped_collection
      resource_class.includes(:region).includes(:adm_region).includes(:organisation) # prevents N+1 queries to your database
    end

    def permitted_params
      params.permit!
    end

    rescue_from ActiveAdmin::AccessDenied do |exception|
      redirect_to '/control/dashboard', :notice => exception.message
    end
  end   # controller

  index do
    selectable_column

    actions(defaults: false) do |resource|
      links = ''.html_safe
      links << link_to(I18n.t('active_admin.view'), resource_path(resource), class: "member_link view_link")
      links << link_to('Принять', new_user_path(user_app_id: resource.id), data: {"user-app-id" => resource.id}, class: "member_link view_link accept_link") unless resource.approved?
      links << '<br/> <br/>'.html_safe
      links << link_to('Отклонить', reject_control_user_app_path(resource), method: :post, remote: true, data: {"user-app-id" => resource.id}, class: "member_link view_link reject_link") unless resource.rejected?
      links
    end
    column :created_at

    column :desired_statuses, :sortable => false, &:human_desired_statuses
    column :adm_region do |user_app|
      links = []
      links << link_to(user_app.region.name, [:control, user_app.region]) if user_app.region
      links << link_to(user_app.adm_region.name, [:control, user_app.adm_region]) if user_app.adm_region
      links.join(", ").html_safe
    end
    column :uic

    column :full_name
    column :phone_formatted, :sortable => false do |user_app|
      status_tag(user_app.phone_formatted, user_app.phone_verified? ? :ok : :error)
    end
    column :email
    column :year_born
    column :sex_male, &:human_sex_male

    column :current_roles, :sortable => false, &:human_current_roles
    column :ip
    column :user do |user_app|
      if user_app.user
        link_to(user_app.user.decorate.organisation_with_user_id, [:control, user_app.user])
      end
    end
  end   # index

  form do |f|
    user_app = f.object
    f.inputs "Роль" do
      UserApp.future_statuses_methods.each do | method_name|
        f.input method_name, as: :boolean,
            input_html: {checked: user_app.send(method_name) == 'Да'}
      end
      # f.input :desired_statuses, as: :radio
      f.input :adm_region
      f.input :region
      f.input :uic
    end

    f.inputs "Личные данные" do
      f.input :last_name
      f.input :first_name
      f.input :patronymic
      f.input :phone
      f.input :phone_verified
      f.input :email
      f.input :year_born
      f.input :sex_male, as: :radio, collection: {"Мужской" => true, "Женский" => false}
    end

    f.inputs "Подробнее" do
      # TODO
      #f.input :current_roles
      f.input :has_car
      f.input :has_video
      f.input :legal_status, label: "Есть юридическое образование?", as: :radio,
          collection: {"Да" => UserApp::LEGAL_STATUS_YES,
                       "Нет" => UserApp::LEGAL_STATUS_NO,
                       "Есть статус адвоката" => UserApp::LEGAL_STATUS_LAWYER}
    end

    f.inputs "Прежний опыт" do
      UserApp.previous_statuses_methods.each do |method_name|
        f.input method_name, :as => :boolean,
            input_html: {checked: user_app.send(method_name) == 'Да'}
      end
      f.input :experience_count
    end

    f.inputs "Аккаунты в соцсетях" do
      UserApp::SOCIAL_ACCOUNTS.each do |provider_key, provider_name|
        f.input 'social_'+provider_key.to_s, :label => (link_to provider_name, social_account_links(provider_key), target: "_blank"), placeholder: social_account_placeholders(provider_key).html_safe
      end
    end

    f.inputs "Дополнительные сведения" do
      f.input :extra
      f.input :organisation
    end

    f.actions
  end   # form

  csv do
    column :id
    column :created_at
    column :adm_region
    column :region
    column :last_name
    column :first_name
    column :patronymic
    column :phone_formatted
    column :phone_verified
    column :email

    column :uic
    column :current_roles
    column :experience_count
    column :previous_statuses

    column("Согласен войти в резерв УИКов") {|user_app| nil}
    column :can_be_coord_region

    column :has_car
    column :has_video

    column :social_accounts
    column :extra

    column("Юр.образование") {|user_app| user_app.object.legal_status & UserApp::LEGAL_STATUS_YES ? "Да":"Нет"}
    column("Адвокатский статус") {|user_app| user_app.object.legal_status == UserApp::LEGAL_STATUS_LAWYER ? "Да":"Нет"}

    column :desired_statuses

    column :year_born
    column :sex_male
    column :organisation
    column :ip
    column :useragent

    UserApp.future_statuses_methods.each do | method_name|
      column(method_name) {|user_app| user_app.send(method_name) ? "Да" : "Нет" }
    end
    UserApp.previous_statuses_methods.each do | method_name|
      column(method_name) {|user_app| user_app.send(method_name) ? "Да" : "Нет" }
    end
  end   # csv

  show do |user_app|
    render 'user_apps/show', user_app: user_app
    active_admin_comments
  end   # show

end
