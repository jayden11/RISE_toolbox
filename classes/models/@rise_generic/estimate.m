function obj=estimate(obj,varargin)
% varargin: data,optimset,optimizer,hessian_type,estim_start_from_mode,estim_parallel
% recursive estimation may be done easily by passing a different
% estim_end_date at the beginning of each estimation run.

nobj=numel(obj);
if nobj==0
    if nargout>1
        error([mfilename,':: when the object is emtpy, nargout must be at most 1'])
    end
    main_defaults=struct('estim_parallel',1,... % number of starting values
        'estim_start_from_mode',[],...
        'estim_start_date','',...
        'estim_end_date','',...
        'estim_max_trials',500,... % maximum number of trials when generating admissible starting values
        'estim_start_vals',[],...
        'estim_general_restrictions',[],... % holds a function that takes as input the model object and returns the
        'estim_linear_restrictions',[],...
        'estim_blocks',[],...
        'estim_priors',[],...
        'estim_penalty',1e+8);
    % violations of the restrictions in a vector for instance in order to impose the max operator ZLB, Linde and Maih
    obj=utils.miscellaneous.mergestructures(optimization.estimation_engine(),...
        main_defaults);
    %         load_data(obj),...
    return
end
nn=length(varargin);
if nn
    if rem(nn,2)~=0
        error([mfilename,':: arguments must come in pairs'])
    end
    discard=[];
    for ii=1:.5*nn
        if strcmp(varargin{2*ii-1},'optimset')
            for jj=1:nobj
                obj(jj).options.optimset=utils.miscellaneous.setfield(obj(jj).options.optimset,varargin{2*ii});
            end
            discard=[2*ii-1,2*ii];
        end
    end
    varargin(discard)=[];
    if ~isempty(varargin)
        for jj=1:nobj
            obj(jj)=set(obj(jj),varargin{:});
        end
    end
end

estim_start_time=clock;
for jj=1:nobj
    if isempty(obj(jj).estimation.posterior_maximization.estim_start_time)
        % maybe we used several optimizers one after the other. In that
        % case the start of the estimation should not change
        obj(jj).estimation.posterior_maximization.estim_start_time=estim_start_time;
    end
end

optim_options=obj(1).options.optimset;
optimizer=obj(1).options.optimizer;
hessian_type=obj(1).options.hessian_type;
estim_start_from_mode=obj(1).options.estim_start_from_mode;
estim_parallel=obj(1).options.estim_parallel;
estim_blocks=obj(1).options.estim_blocks;
if ~isempty(estim_blocks)
    estim_blocks=create_estimation_blocks(obj(1),estim_blocks);
end

% Load the function that computes the likelihood
% preliminary checks:
param_names={obj(1).estimation.priors.name};
% Load the function that computes the likelihood
estim_general_restrictions=cell(1,nobj);
estim_gen_restr_args=cell(1,nobj);
for ii=1:nobj
    if ~isequal(param_names,{obj(ii).estimation.priors.name})
        error([mfilename,':: optimization parameters should be the same across all models and ordered in the same way'])
    end
    % this will be useful when deciding to check for stability in the markov switching model
    obj(ii).estimation_under_way=true;
    % %     isunif=strcmp('uniform',{obj(ii).estimation.priors.prior_distrib});
    % %     is_uniform=[is_uniform,isunif(:)];
    % load the mode
    obj(ii)=load_mode(obj(ii));
    % Initially set the filtering/smoothing flag to false (during estimation).
    % This is especially important given that the objective function could be
    % optimal_simple_rule_posterior, in which case there is no filtering going
    % on.
    obj(ii).options.kf_filtering_level=0;
    if ~isempty(obj(ii).options.estim_general_restrictions)
        if iscell(obj(ii).options.estim_general_restrictions)
            estim_general_restrictions(ii)=obj(ii).options.estim_general_restrictions(1);
            estim_gen_restr_args{ii}=obj(ii).options.estim_general_restrictions(2:end);
        else
            estim_general_restrictions{ii}=obj(ii).options.estim_general_restrictions;
            estim_gen_restr_args{ii}={};
        end
        % collect the information about the degree of filtering
        % 0 (no filters), 1(filtered), 2(filtered+updated), 3(filtered+updated+smoothed)
        obj(ii).options.kf_filtering_level=estim_general_restrictions{ii}();
        if obj(ii).options.kf_filtering_level && obj(ii).is_optimal_simple_rule_model
            error([mfilename,':: Cannot do filtering under estimation of optimal simple rules'])
        end
    end
end

% this will record the different problems encounter during estimation
list_of_issues=cell(0);

if ~isempty(estim_start_from_mode) && ~islogical(estim_start_from_mode)
    estim_start_from_mode=logical(estim_start_from_mode);
end
% prior_trunc=obj.options.prior_trunc;
% debug=obj(1).options.debug;

[obj,issue,retcode]=load_data(obj);
if retcode
    if ~all([obj.is_optimal_simple_rule_model])
        error([mfilename,':: ',utils.error.decipher(retcode)])
    end
end
if ~isempty(issue)
    list_of_issues=[list_of_issues;{issue}];
end
% eventually I should put options for recursive estimation
% and for passing new data to the model on the fly.

xmode=obj(1).estimation.posterior_maximization.mode;
response='n';
if ~isempty(xmode)
    if ~isempty(estim_start_from_mode)
        if estim_start_from_mode
            response='y';
        else
            response='n';
        end
    else
        response='';
        while ~ismember(response,{'y','n'})
            response=input('previous estimation found. Do you want to load the mode? [y/n]','s');
        end
    end
end
switch response
    case 'y'
        x0=xmode;
    case 'n'
        x0=[obj(1).estimation.priors.start];
    otherwise
end
x0=x0(:);
lb=[obj(1).estimation.priors.lower_bound]; lb=lb(:);
ub=[obj(1).estimation.priors.upper_bound]; ub=ub(:);

% get the linear restrictions if any. a_func takes a2tilde as input and
% returns "a", while a2tilde_func takes "a" as input and returns a2tilde.
% restr_var_data_func takes obj as input and returns a structure with
% ytilde, Xtilde, which are the transformed y and X given the restrictions.
% na2tilde<=npar is the number of parameters to estimate
%-----------------------------------------------------------------------
[a_func,a2tilde_func,restr_var_data_func,npar_short]=setup_linear_restrictions(obj);

npar=size(x0,1);
if isa(obj,'rfvar') && ...
        obj.markov_chains.regimes_number==1 && ...
        obj.options.vp_analytical_post_mode
    vdata=restr_var_data_func(obj);
    a_prior=[obj.estimation.priors.prior_mean];
    a_prior=a_prior(vdata.estim_locs);
    a_prior=a_prior(:);
    va_prior=[obj.estimation.priors.prior_stdev];
    va_prior=diag(va_prior(vdata.estim_locs).^2);
    a2tilde_prior=a2tilde_func(a_prior);
    va2tilde_prior=a2tilde_func(va_prior,true);
    
    [a2tilde_post,~,resid_post]=vartools.analytic_posterior_mode(...
        vdata.Xtilde,vdata.ytilde,a2tilde_prior,va2tilde_prior);
    resid_post=reshape(resid_post,obj.endogenous.number(end),[]);
    [nvars,nobs]=size(resid_post);
    a_post=a_func(a2tilde_post);
    
    x1=nan(npar,1);
    x1(vdata.estim_locs)=a_post;
    vcov=(resid_post*resid_post.')/(nobs-npar_short/nvars);
    sdev=sqrt(diag(vcov));
    for irow=1:nvars
        sig_name=sprintf('sig_%0.0f_%0.0f',irow,irow);
        sig_pos=strcmp(sig_name,vdata.orig_estim_names);
        x1(sig_pos)=sdev(irow);
        for icol=1:irow-1
            corr_name=sprintf('omg_%0.0f_%0.0f',irow,icol);
            corr_pos=strcmp(corr_name,vdata.orig_estim_names);
            x1(corr_pos)=vcov(irow,icol)/(sdev(irow)*sdev(icol));
        end
    end
%     keyboard
    H=eye(npar);
    
    viol=[];
    funevals=0;
else
    [nonlcon,nconst]=reprocess_nonlinear_restrictions(obj(1).parameter_restrictions);
    % the functions in obj(1).parameter_random_draws_restrictions only check
    % whether the restrictions are violated or not but do not give the strength
    % of the violation, which we need in order to apply DEB. So we need to use
    % the reprocessed form.
    
    % initialize the number of function calls
    %----------------------------------------
    funevals=0;
    Nsim=max(1,estim_parallel);
    % now shorten everything
    %-----------------------
    x0=a2tilde_func(x0);
    x0=[x0,nan(npar_short,Nsim-1)];
    f0=nan(1,Nsim);
    lb=a2tilde_func(lb);
    ub=a2tilde_func(ub);
    bad=lb>ub;
    if any(bad)
        tmp=lb;
        lb(bad)=ub(bad);
        ub(bad)=tmp(bad);
    end
    % all objects are evaluated at the same point. Without a second argument,
    % this is exactly what will happen.
    [~,f0(1),~,retcode0,viol]=big_wrapper(x0(:,1));
    if retcode0||any(viol>0)
        % first check constraint violations
        f0(1)=obj(1).options.estim_penalty;
    end
    % the objects are automatically updated and potentially contain crucial
    % information going forward. In particular, they contain information
    % about whether the models are stationary or not.
    
    if f0(1)<obj(1).options.estim_penalty
        beg=2;
    else
        beg=1;
    end
    
    %% disable those elements
    warning('off','MATLAB:nearlySingularMatrix')
    warning('off','MATLAB:illConditionedMatrix')
    
    fprintf(1,'%s\n','Looking for good enough start values. Please wait...');
    for ii=beg:Nsim
        NotDone=true;
        iter=0;
        while NotDone
            [xtest,ftest,retcode]=utils.estim.generate_starting_point(@big_wrapper);
            if ftest<obj(1).options.estim_penalty
                NotDone=false;
                f0(ii)=ftest;
                x0(:,ii)=xtest;
            end
            iter=iter+1;
            if iter>=obj(1).options.estim_max_trials
                error([mfilename,':: No admissible starting value after ',...
                    int2str(obj(1).options.estim_max_trials),' trials'])
            else
                fprintf(1,'%3.0d :: %s\n',iter,utils.error.decipher(retcode));
            end
        end
        disp(['Starting value # ',int2str(ii),' found after ',int2str(iter),' iterations'])
        ratio=ii/Nsim;
        fprintf(1,'%s\n',['...', num2str(100*ratio),'% done']);
    end
    
    [x1,f1,H,issue,viol,obj]=big_wrapper(x0,'estimate'); %#ok<ASGLU>
    % both vector x1 and H here are short: extend them
    %-------------------------------------------------
    x1 = a_func(x1);
    H = a_func(H,true); % the second arguments indicates that it is a covariance term
    
    viol=viol(viol>0);
end
numberOfActiveInequalities=numel(viol);

% make the hessian positive definite if necessary
[Hc,Hinv] = utils.hessian.conditioner(H);
if max(abs(Hc(:)-H(:)))>1e-6
    warning([mfilename,':: non-positive definite hessian made diagonally dominant']) %#ok<WNTAG>
    H=Hc; clear Hc
    Hinv=inv(H);
end
% the standard deviations
SD=sqrt(diag(Hinv));

if ~isempty(issue)
    list_of_issues=[list_of_issues;{issue}];
end

estim_end_time=clock;
for ii=1:nobj
    % set the end time for estimation, even if it does not include the
    % smoothing part below.
    obj(ii).estimation.posterior_maximization.estim_end_time=estim_end_time;
    % set the filtering/smoothing flag to 3 in order to get out the final
    % outputs with the smoothed and filtered variables (if feasible)
    
    [log_post,log_lik,log_prior,~,~,obj(ii)]=conclude_estimation(obj(ii),x1);
    
    % capture the final parameters and their standard deviations
    obj(ii).estimation.posterior_maximization.mode=x1;
    obj(ii).estimation.posterior_maximization.mode_stdev=SD;
    
    % rebuild the parameter object. This can be done now coz estimation_under_way is set to false
    % log_mdd=.5*npar*log(2*pi)-.5*log(det(H))+log_post;
    % or alternatively
    log_mdd=.5*npar*log(2*pi)+.5*log(det(Hinv))+log_post;
    
    obj(ii).estimation.posterior_maximization.log_prior=log_prior(1);
    obj(ii).estimation.posterior_maximization.log_endog_prior=log_prior(2);
    obj(ii).estimation.posterior_maximization.log_post=log_post;
    obj(ii).estimation.posterior_maximization.log_lik=log_lik;
    obj(ii).estimation.posterior_maximization.log_marginal_data_density_laplace=log_mdd;
    obj(ii).estimation.posterior_maximization.active_inequalities_number=numberOfActiveInequalities;
    obj(ii).estimation.posterior_maximization.vcov=Hinv;
    obj(ii).estimation.posterior_maximization.funevals=funevals;
    
    obj(ii).list_of_issues=list_of_issues;
    
    if isdir(obj(ii).options.results_folder)
        save([obj(ii).options.results_folder,filesep,'estimation',filesep,...
            'estimated_model'],'obj','x1','x0','f1','f0','H','Hinv')
    end
end
% disp Estimation results
print_estimation_results(obj);

warning('on','MATLAB:nearlySingularMatrix')
warning('on','MATLAB:illConditionedMatrix')

    function [x1,f1,H,issue,viol,finalobj]=big_wrapper(x0,action)
        if nargin<2
            action='eval';
            if nargin<1
                x0=lb+(ub-lb).*rand(npar_short,1);
            end
        end
        violLast=[];
        xLast=[];
        viol=[];
        ngen_restr=[];
        switch action
            case 'estimate'
                PROBLEM_=struct('objective',@fh_wrapper,...
                    'x0',x0,...
                    'lb',lb,...
                    'ub',ub,...
                    'nonlcon',@nonlcon_with_gradient,... % the nonlinear constraints restrictions take the same inputs as fh_wrapper
                    'options',optim_options,...
                    'solver',optimizer);
                
                [x1,f1,H,issue]=optimization.estimation_engine(PROBLEM_,hessian_type,estim_blocks);
            case 'eval'
                [f1,retcode_0]=fh_wrapper(x0);
                x1=x0;
                H=[];
                issue=retcode_0;
                viol=nonlcon_with_gradient(x0);
            otherwise
                error(['unknown type of action ',action])
        end
        finalobj=obj;
        
        function [minus_log_post,retcode]=fh_wrapper(xtilde)
            % this function returns the minimax if there are many objects
            % evaluated simultaneously
            
            % all objects are evaluated at the same point
            % the reason you want to output the object here is because it potentially
            % contains crucial information going forward. In particular, it contains
            % information about whether the model is stationary or not.
            
            % expand x before doing anything
            %-------------------------------
            x=a_func(xtilde);
            
            fval=obj(1).options.estim_penalty*ones(1,nobj);
            for mo=1:nobj
                [fval(mo),~,~,~,retcode,obj(mo)]=log_posterior_kernel(obj(mo),x);
                if retcode
                    break
                end
            end
            funevals=funevals+1;
            % Now take the negative for minimization
            minus_log_post=-min(fval);
            % nonlinear constraints might be incompatible with blockwise
            % optimization. In that case, it is better to compute the
            % restriction violation while evaluating the objective and save
            % the results to pass on to the optimizer when it calls the
            % nonlinear constraints.
            if retcode
                if isempty(ngen_restr)
                    % then we still have not found a good starting point
                    % and therefore, there is no point in looking at the
                    % constraints.
                else
                    violLast=ones(nconst+ngen_restr,1)*realmax/(nconst+ngen_restr);
                end
            else
                violLast=mynonlinear_constraints(x,obj);
            end
            % update this element right here, so that it is ready when
            % calling nonlcon_with_gradient
            xLast=x;
        end
        
        function viol=mynonlinear_constraints(x,obj) %#ok<INUSL>
            % this function assumes that the first argument has already
            % been pushed into the second one... I will need to make sure
            % that this is actually the case.
            viol_general=[];
            viol_simple=[];
            for iobj=1:nobj
                vv=nonlcon(obj(iobj).parameter_values);
                viol_simple=[viol_simple,vv(:)]; %#ok<AGROW>
                if ~isempty(estim_general_restrictions{iobj})
                    vv=estim_general_restrictions{iobj}(obj(iobj),estim_gen_restr_args{iobj}{:});
                    viol_general=[viol_general,vv(:)]; %#ok<AGROW>
                end
            end
            if isempty(ngen_restr)
                ngen_restr=numel(viol_general);
            end
            viol=[viol_simple(:);viol_general(:)];
        end
        
        function [viol,grad]=nonlcon_with_gradient(xtilde)
            grad=[];
            % expand x before doing anything
            %-------------------------------
            x=a_func(xtilde);
            if isequal(x,xLast)
                viol=violLast;
            else
                % % % % % % % % % % % %                 warning('evaluating constraints before computing log-posterior ')
                thisobj=assign_estimates(obj,x);
                % % % % % % % % % % % %                 thisobj=filter(thisobj);
                viol=mynonlinear_constraints(x,thisobj);
            end
        end
    end
end

function [nonlcon,nconst]=reprocess_nonlinear_restrictions(nonlcon)
% transform the nonlinear constraints. I would like to keep the
% flexibility of knowning what parameters enter the constraints and
% so I do not do this in format parameters
nconst=numel(nonlcon);
for iconstr=1:nconst
    % remove semicolon
    nonlcon{iconstr}=strrep(nonlcon{iconstr},';','');
    % now remove inequalities
    cutoff_type={'>=','<=','>','<','='};
    for itype=1:numel(cutoff_type)
        cutoff_locs=strfind(nonlcon{iconstr},cutoff_type{itype});
        if ~isempty(cutoff_locs)
            cutoff_type=cutoff_type{itype};
            break
        end
    end
    if ~isempty(cutoff_locs)
        span=length(cutoff_type);
        left=nonlcon{iconstr}(1:cutoff_locs-1);
        right=nonlcon{iconstr}(cutoff_locs+span:end);
        switch cutoff_type
            case '>='
                nonlcon{iconstr}=[right,'-(',left,')-eps;'];
            case '<='
                nonlcon{iconstr}=[left,'-(',right,')-eps;'];
            case '>'
                nonlcon{iconstr}=[right,'-(',left,');'];
            case '<'
                nonlcon{iconstr}=[left,'-(',right,');'];
            case '='
                nonlcon{iconstr}=['abs(',left,'-(',right,'))-eps;'];
        end
    end
end
nonlcon=cell2mat(nonlcon(:)');
nonlcon=nonlcon(1:end-1);
if isempty(nonlcon)
    nonlcon='0';
    nconst=1;
end
nonlcon=str2func(['@(M)[',nonlcon,']']);
end
% function rst=push_time_series(C)
% rst=ts(C{1},C{2},C{3});
% end
